#Requires -Version 4

<#
	.SYNOPSIS
		Remediate an account which has had breached credentials.

	.DESCRIPTION
		This script will remediate an account which has had credentials breached. Commonly, an attacker will extend
        their access by sharing their data. Simply resetting the users password is not enough to prevent this.

        The following actions are performed
            1. Reset users password (if user is a cloud managed user, not federated)
            2. Enable Multifactor authentication
            3. Revoke all refresh tokens, forcing user to re-logon
            4. Disable forwarding rules
            5. Disable anonymous calendar sharing
            6. Remove delegates that are not SELF
            7. Remove Mailbox Forwarding options

        Actions can be disabled using No* PARAMs, for instance, to not enable MFA, run script with -NoMFA param

        Forensic information is dumped unless the -NoForensics param is used. This forensic information contains
        details about the mailbox, inbox rules, delegates, calendar sharing, auditing information of the user prior
        to the remediation actions. This can be useful for further investigation, or potential reversal of any of the
        actions performed.

        Parts of this script and some actions have been taken from Brandon Koeller's script
        https://github.com/OfficeDev/O365-InvestigationTooling/blob/master/RemediateBreachedAccount.ps1

    .PARAMETER NoForensics
    .PARAMETER NoAudit
    .PARAMETER NoPasswordReset
    .PARAMETER NoMFA
    .PARAMETER NoDisableForwardingRules
    .PARAMETER NoRevokeRefreshToken
    .PARAMETER NoRemoveCalendarPublishing
    .PARAMETER NoRemoveDelegates
    .PARAMETER NoRemoveMailboxForwarding

    .PARAMETER  RemediateAll
        Specifying this parameter will automate the remediation process, by default, confirmation is required.
        WARNING: This does not allow you to confirm the mailbox before remediation

	.EXAMPLE
		PS C:\> .\Remediate-BreachedAccount -UPN joe@contoso.com

	.EXAMPLE
		PS C:\> .\Remediate-BreachedAccount -UPN joe@contoso.com -NoMFA

	.NOTES
		Cam Murray
		Field Engineer - Microsoft
		cam.murray@microsoft.com
		
		Last update: 30 March 2017

	.LINK
		about_functions_advanced

#>

Param(
    [CmdletBinding()]
    [Parameter(Mandatory=$True)]
    [String]$UPN,
    [switch]$NoForensics,
    [switch]$NoAudit,
    [Switch]$NoPasswordReset,
    [switch]$NoMFA,
    [switch]$NoDisableForwardingRules,
    [switch]$NoRevokeRefreshToken,
    [switch]$NoRemoveCalendarPublishing,
    [switch]$NoRemoveDelegates,
    [switch]$NoRemoveMailboxForwarding,
    [switch]$ConfirmAll
)

#region Functions

Function Reset-Password {
    # Function reset's the user password with a random password
	Param(
		[string]$UPN
	)
    Write-Host "[$UPN] Resetting password.."
    $Password = Set-MsolUserPassword -UserPrincipalName $UPN -ForceChangePassword:$True
    Return $Password;
}

Function Enable-MFA {
    # Turns on MFA for the user
    Param(
        [string]$UPN
    )

    Write-Host "[$UPN] Enabling MFA"

    # Create the StrongAuthenticationRequirement object and insert required settings
    $mf = New-Object -TypeName Microsoft.Online.Administration.StrongAuthenticationRequirement
    $mf.RelyingParty = "*"
    $mfa = @($mf)

    # Enable MFA for a user
    Set-MsolUser -UserPrincipalName $UPN -StrongAuthenticationRequirements $mfa

}

Function Enable-Auditing {
    # Ensures auditing is turned on
	Param(
		[string]$UPN
	)
    Write-Host "[$UPN] Enabling Auditing.."
    Set-Mailbox -Identity $UPN -AuditEnabled:$true -AuditLogAgeLimit 365 -WarningAction:SilentlyContinue
}

Function Disable-ForwardingRules {
    # Disable forwarding rules to external domains
	Param(
		[string]$UPN
	)
    Write-Host "[$UPN] Disabling forwarding rules.."
    
    if($ConfirmAll) { $Confrimation = $false; } else { $Comfirmation = $true; }
    Get-InboxRule -Mailbox $upn | Where-Object {(($_.Enabled -eq $true) -and (($_.ForwardTo -ne $null) -or ($_.ForwardAsAttachmentTo -ne $null) -or ($_.RedirectTo -ne $null) -or ($_.SendTextMessageNotificationTo -ne $null)))} | Disable-InboxRule -Confirm:$Confrimation

}

Function Dump-Forensics {
    # This script exports current settings about the user which can be used for forensics information later
	Param(
		[string]$UPN,
        [string]$MailboxIdentity
	)
    
    $ForensicsFolder = "$PSScriptRoot\Forensics\$UPN\"

    Write-Host "[$UPN] Dumping forensics to $ForensicsFolder"
    if(!(Test-Path($ForensicsFolder))) { mkdir $ForensicsFolder | Out-Null }

    Get-Mailbox -Identity $UPN | Export-CliXml "$ForensicsFolder\$UPN-mailbox.xml" -Force | Out-Null
    Get-InboxRule -Mailbox $UPN | Export-CliXml "$ForensicsFolder\$UPN-inboxrules.xml" -Force | Out-Null
    Get-MailboxCalendarFolder -Identity "$($MailboxIdentity):\Calendar" | Export-CliXml "$ForensicsFolder\$UPN-MailboxCalendarFolder.xml" -Force | Out-Null
    Get-MailboxPermission -Identity $upn | Where-Object {($_.IsInherited -ne "True") -and ($_.User -notlike "*SELF*")} | Export-CliXml "$ForensicsFolder\$UPN-MailboxDelegates.xml" -Force | Out-Null

    # Audit log if it exists
    
    $startDate = (Get-Date).AddDays(-7).ToString('MM/dd/yyyy') 
    $endDate = (Get-Date).ToString('MM/dd/yyyy')

    Search-UnifiedAuditLog -StartDate $startDate -EndDate $endDate -UserIds $upn | Export-Csv -Path "$ForensicsFolder\$UPN-AuditLog.csv" -NoTypeInformation

}

Function Revoke-RefreshToken {
    # Revokes Refresh Token for User, forcing logged in applications to re-logon.
	Param(
		[string]$UPN
	)
    
    $MsolUser = Get-MsolUser -UserPrincipalName $UPN

    Write-Host "[$UPN] Revoking Refresh Tokens for Object ID $($MsolUser.ObjectId)"

    Revoke-AzureADUserAllRefreshToken -ObjectId $($MsolUser.ObjectID)
    
}

Function Remove-CalendarPublishing {
    # Removes anonymous calendar publishing for the user
	Param(
        [string]$UPN,
		[string]$MailboxIdentity
	)
    
    Write-Host "[$UPN] Removing Anonymous Calendar Publishing for User.."

    # We have to check first, because a watson dump exception occurrs if we attempt to run the command when it's not enabled
    if((Get-MailboxCalendarFolder -Identity "$($MailboxIdentity):\Calendar").PublishEnabled -eq $true) {
        Set-MailboxCalendarFolder -Identity "$($MailboxIdentity):\Calendar" -PublishEnabled:$false
    }
}

Function Remove-MailboxDelegates {
    # Removes Mailbox Delegates from Mailbox where not SELF
	Param(
        [string]$UPN
	)
    
    Write-Host "[$UPN] Removing mailbox delegates.."

    $mailboxDelegates = Get-MailboxPermission -Identity $upn | Where-Object {($_.IsInherited -ne "True") -and ($_.User -notlike "*SELF*")}
    
    foreach ($delegate in $mailboxDelegates) 
    {
        Remove-MailboxPermission -Identity $upn -User $delegate.User -AccessRights $delegate.AccessRights -InheritanceType All -Confirm:$false
    }

}

Function Remove-MailboxForwarding {
    # Removes Mailbox Forwarding Options from Mailbox
	Param(
        [string]$UPN
	)
    Write-Host "[$UPN] Removing Mailbox Forwarding.."

    Set-Mailbox -Identity $upn -DeliverToMailboxAndForward $false -ForwardingSmtpAddress $null -WarningAction:SilentlyContinue

}

#endregion

#region start

Start-Transcript -Path "$PSScriptRoot\Remediate-$UPN.txt"
$Notes = ""

#endregion

#region prechecks

# Check to see if we are connected to MSOL and Exchange Online first
try {Get-MsolCompanyInformation -ErrorAction:stop | Out-Null} catch {Write-Error "This script requires you to be connected to MSOL v1 as a Global Administrator. Run Connect-MsolService first"}
try {Get-AzureADTenantDetail -ErrorAction:stop | Out-Null} catch {Write-Error "This script requires you to be connected to Azure AD PowerShell v2.0 as a Global Administrator. Run Connect-AzureAD first"}

$Mailbox = Get-Mailbox $UPN -ErrorAction:stop
$MsolUser = Get-MsolUser -UserPrincipalName $UPN

if(!$Mailbox) {
    Write-Error "Cannot get mailbox for $UPN. Either there is no mailbox, or you are not connected to Exchange Online"; exit
}

Write-Host "[$UPN] Mailbox Identity: $($Mailbox.Identity), Display Name: $($Mailbox.DisplayName)"
 
if(!$ConfirmAll) {
    # Perform confirmation of the mailbox before continuing
    $options = [System.Management.Automation.Host.ChoiceDescription[]] @("&Remediate", "&Quit")
    $result = $host.UI.PromptForChoice($null , "`nConfirm Account?" , $Options,1)
    if($result -eq 1) { exit }
}

if(!$NoForensics) {
    Write-Host "[$UPN] Forensics functions.."
    Dump-Forensics -UPN $UPN -MailboxIdentity $Mailbox.Identity
}

if(!$NoPasswordReset) {
    # Determine if user is a federated user, turn off password reset if it is federated and notify that we must set on-premises
    $Domain = $MsolUser.UserPrincipalName.Split("@")[1]
    if((Get-AzureADDomain -Name $Domain).AuthenticationType -ne "Managed") {
        Write-Host "Not managed domain"
        $NoPasswordReset = $true
        $Notes += "`nDomain is Federated, password must be reset in on-premises AD"
    }
}

#endregion

#region remediation

# Remediation actions

Write-Host "[$UPN] Remediation beginning.."

if(!$NoPasswordReset) { $NewPassword = Reset-Password -UPN $UPN }
if(!$NoMFA) { Enable-MFA -UPN $UPN }
if(!$NoAudit) { Enable-Auditing -UPN $UPN }
if(!$NoRevokeRefreshToken) { Revoke-RefreshToken -UPN $UPN }
if(!$NoDisableForwardingRules ) { Disable-ForwardingRules -UPN $UPN }
if(!$NoRemoveCalendarPublishing ) { Remove-CalendarPublishing -UPN $UPN -MailboxIdentity $Mailbox.Identity }
if(!$NoRemoveDelegates ) { Remove-MailboxDelegates -UPN $UPN }
if(!$NoRemoveMailboxForwarding ) { Remove-MailboxForwarding -UPN $UPN }

#endregion

#region report

Write-Host "`n`nRemediation report for $UPN" -ForegroundColor Green
if(!$NoPasswordReset) { Write-Host "New Password: $NewPassword" }

Write-Host "`nActions performed"
if(!$NoForensics) { Write-Host " - Forensic information dumped" }
if(!$NoPasswordReset) { Write-Host " - Password Reset" }
if(!$NoMFA) { Write-Host " - Enabled MFA" }
if(!$NoAudit) { Write-Host " - Audit Enabled" }
if(!$NoRevokeRefreshToken) { Write-Host " - Revoked Refresh Tokens" }
if(!$NoDisableForwardingRules) { Write-Host " - Disabled Forwarding Rules" }
if(!$NoRemoveCalendarPublishing) { Write-Host " - Remove Calendar Publishing" }
if(!$NoRemoveDelegates) { Write-Host " - Removed Mailbox Delegates" }
if(!$NoRemoveMailboxForwarding ) { Write-Host " - Removed Mailbox Forwarding" }

Write-Host "`nAdditional notes" -ForegroundColor Green
Write-Host $Notes

#endregion

Stop-Transcript