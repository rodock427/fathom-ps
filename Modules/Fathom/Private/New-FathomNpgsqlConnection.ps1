function New-FathomNpgsqlConnection {
    <#
    .SYNOPSIS
        An unopened Npgsql connection, from the Npgsql that SimplySql ships (a required module).
    .DESCRIPTION
        SimplySql loads Npgsql privately, so its types can't be named directly. Use an Npgsql
        already loaded in the process if there is one, else load SimplySql's copy.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object in memory; nothing changes.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ConnectionString)

    if (-not $script:NpgsqlConnectionType) {
        $assembly = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'Npgsql' } | Select-Object -First 1
        if (-not $assembly) {
            $simplySql = Get-Module -Name SimplySql
            $assembly = [Reflection.Assembly]::LoadFrom((Join-Path -Path $simplySql.ModuleBase -ChildPath 'bin/PS7/Npgsql.dll'))
        }
        $script:NpgsqlConnectionType = $assembly.GetType('Npgsql.NpgsqlConnection', $true)
    }
    $script:NpgsqlConnectionType::new($ConnectionString)
}
