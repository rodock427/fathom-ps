function Connect-FathomDatabase {
    <#
    .SYNOPSIS
        Opens the Postgres connection that every other Fathom command uses.
    .DESCRIPTION
        One connection per runspace: PSU runs jobs and app pages side by side in one process,
        and each gets its own.
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
    Disconnect-FathomDatabase
    $connection = New-FathomNpgsqlConnection -ConnectionString (ConvertTo-NpgsqlConnectionString -Dsn $Dsn)
    try {
        $connection.Open()
    } catch {
        $connection.Dispose()
        throw
    }
    $script:Sessions[(Get-FathomConnectionName)] = [pscustomobject] @{ Connection = $connection; Transaction = $null }
}
