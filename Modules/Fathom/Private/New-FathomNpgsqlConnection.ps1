function New-FathomNpgsqlConnection {
    <#
    .SYNOPSIS
        An unopened Npgsql connection, from the Npgsql that SimplySql ships (a required module).
    .DESCRIPTION
        SimplySql loads Npgsql privately, so its types can't be named directly. Load our own copy
        of SimplySql's Npgsql, so Fathom behaves the same in PSU, in tests and in a console
        (SimplySql configures its copy differently). If the process already has an Npgsql that
        blocks loading another, use that one.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object in memory; nothing changes.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ConnectionString)

    if (-not $script:NpgsqlConnectionType) {
        $path = Join-Path -Path (Get-Module -Name SimplySql).ModuleBase -ChildPath 'bin/PS7/Npgsql.dll'
        try {
            $assembly = [Reflection.Assembly]::LoadFrom($path)
        } catch {
            $assembly = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'Npgsql' } | Select-Object -First 1
            if (-not $assembly) { throw }
        }
        $script:NpgsqlConnectionType = $assembly.GetType('Npgsql.NpgsqlConnection', $true)
    }
    $script:NpgsqlConnectionType::new($ConnectionString)
}
