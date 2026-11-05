<#
.SYNOPSIS
    Imports an existing debug log file as a server's usage history. Started from Administration.
#>
param(
    [Parameter(Mandatory)] [string] $ServerId,
    [Parameter(Mandatory)] [string] $Path
)
Import-Module Fathom

# FathomDsn is a PSU secret variable; LM_POSTGRES_DSN covers a DSN set on the PSU service instead.
Connect-FathomDatabase -Dsn ($FathomDsn ?? $env:LM_POSTGRES_DSN)
try {
    Import-FathomDebugLog -ServerId $ServerId -Path $Path
} finally {
    Disconnect-FathomDatabase
}
