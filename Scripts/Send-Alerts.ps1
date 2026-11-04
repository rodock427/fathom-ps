<#
.SYNOPSIS
    Records current alerts and mails a digest. Scheduled every 5 minutes; sends nothing until
    alerts are enabled (Set-FathomAlertSetting -Enabled $true).
#>
Import-Module Fathom

# FathomDsn is a PSU secret variable; LM_POSTGRES_DSN covers a DSN set on the PSU service instead.
Connect-FathomDatabase -Dsn ($FathomDsn ?? $env:LM_POSTGRES_DSN)
try {
    # FathomSmtpCredential: optional PSU secret (PSCredential) for an SMTP server that needs a login.
    Send-FathomAlert -Credential $FathomSmtpCredential
} finally {
    Disconnect-FathomDatabase
}
