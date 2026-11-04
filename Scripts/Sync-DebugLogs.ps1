<#
.SYNOPSIS
    Reads new lmgrd debug-log lines for every enabled server. Scheduled every minute.
#>
Import-Module Fathom

# FathomDsn is a PSU secret variable; LM_POSTGRES_DSN covers a DSN set on the PSU service instead.
Connect-FathomDatabase -Dsn ($FathomDsn ?? $env:LM_POSTGRES_DSN)
try {
    Get-FathomServer -Enabled | Sync-FathomDebugLog
} finally {
    Disconnect-FathomDatabase
}
