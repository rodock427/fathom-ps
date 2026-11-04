<#
.SYNOPSIS
    Creates or upgrades Fathom's tables. Run once after installing or updating; safe to repeat.
#>
Import-Module Fathom

# Not part of the schedules: schema changes take table locks, which the per-minute jobs shouldn't.
Connect-FathomDatabase -Dsn ($FathomDsn ?? $env:LM_POSTGRES_DSN)
try {
    Initialize-FathomSchema
    'Fathom schema is up to date.'
} finally {
    Disconnect-FathomDatabase
}
