<#
.SYNOPSIS
    Looks up the users and hosts Fathom has seen in Active Directory. Scheduled hourly; does
    nothing until directory lookups are on (Set-FathomDirectorySetting -Enabled $true).
#>
Import-Module Fathom

# FathomDsn is a PSU secret variable; LM_POSTGRES_DSN covers a DSN set on the PSU service instead.
Connect-FathomDatabase -Dsn ($FathomDsn ?? $env:LM_POSTGRES_DSN)
try {
    # FathomDirectoryCredential: optional PSU secret (PSCredential) when the PSU service account can't read AD.
    Sync-FathomDirectory -Credential $FathomDirectoryCredential
} finally {
    Disconnect-FathomDatabase
}
