<#
.SYNOPSIS
    Polls every enabled server with lmstat: live usage, seat limits, up/down. Scheduled every 5 minutes.
#>
Import-Module Fathom

# FathomDsn is a PSU secret variable; LM_POSTGRES_DSN covers a DSN set on the PSU service instead.
Connect-FathomDatabase -Dsn ($FathomDsn ?? $env:LM_POSTGRES_DSN)
try {
    # lmutil comes from FATHOM_LMUTIL, else PATH.
    Get-FathomServer -Enabled | Sync-FathomLiveStatus
} finally {
    Disconnect-FathomDatabase
}
