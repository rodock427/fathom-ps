function ConvertTo-NpgsqlConnectionString {
    <#
    .SYNOPSIS
        Converts a libpq URI (Fathom's LM_POSTGRES_DSN format) to an Npgsql connection string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Dsn
    )

    # Already key=value: Npgsql reads it as-is.
    if ($Dsn -notmatch '^postgres(ql)?://') {
        return $Dsn
    }

    $uri = [uri] $Dsn
    $user, $password = $uri.UserInfo -split ':', 2
    $parts = [ordered] @{
        Host     = $uri.Host
        Port     = if ($uri.Port -gt 0) { $uri.Port } else { 5432 }
        Database = $uri.AbsolutePath.TrimStart('/')
        Username = [uri]::UnescapeDataString($user)
    }
    if ($password) {
        $parts.Password = [uri]::UnescapeDataString($password)
    }

    foreach ($pair in $uri.Query.TrimStart('?') -split '&' -ne '') {
        $key, $value = $pair -split '=', 2
        # Dropping an option like sslmode silently would downgrade security, so refuse unknowns.
        if ($key -ne 'sslmode') {
            throw "Unsupported DSN option '$key'. Use a key=value connection string instead."
        }
        $parts['SSL Mode'] = $value
    }

    ($parts.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join ';'
}
