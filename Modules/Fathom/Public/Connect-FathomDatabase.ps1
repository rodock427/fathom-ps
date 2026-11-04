function Connect-FathomDatabase {
    <#
    .SYNOPSIS
        Opens the Postgres connection that every other Fathom command uses.
    .EXAMPLE
        Connect-FathomDatabase -Dsn 'postgresql://fathom:secret@db01:5432/license_manager'
    #>
    [CmdletBinding()]
    param(
        # libpq URI or Npgsql connection string. Defaults to PSU's FathomDsn secret, then
        # LM_POSTGRES_DSN (the variable Fathom reads).
        [string] $Dsn = (Get-FathomDefaultDsn)
    )

    if (-not $Dsn) {
        throw 'No database configured. Pass -Dsn, add a FathomDsn secret in PSU, or set LM_POSTGRES_DSN.'
    }

    # Reconnecting replaces the old connection, so a changed DSN always wins.
    if (Test-SqlConnection -ConnectionName $script:ConnectionName) {
        Close-SqlConnection -ConnectionName $script:ConnectionName
    }

    $connection = @{
        ConnectionName   = $script:ConnectionName
        ConnectionString = ConvertTo-NpgsqlConnectionString -Dsn $Dsn
    }
    Open-PostGreConnection @connection
}
