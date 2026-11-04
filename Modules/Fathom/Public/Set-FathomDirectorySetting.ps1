function Set-FathomDirectorySetting {
    <#
    .SYNOPSIS
        Changes the directory lookup settings. Only the parameters you pass change.
    .EXAMPLE
        Set-FathomDirectorySetting -Enabled $true -Server dc01.corp.example
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Fathom.DirectorySetting')]
    param(
        # Off by default: nothing is looked up until this is on.
        [bool] $Enabled,

        # A domain controller or domain to ask. Empty for the PSU server's own domain.
        [AllowEmptyString()]
        [string] $Server,

        # Each user and host is looked up again after this many hours.
        [ValidateRange(1, 8760)]
        [int] $RefreshHours
    )

    $columns = [ordered] @{ Enabled = 'enabled'; Server = 'server'; RefreshHours = 'refresh_hours' }
    $assignments = foreach ($name in $columns.Keys | Where-Object { $PSBoundParameters.ContainsKey($_) }) {
        "$($columns[$name]) = @$($columns[$name])"
    }
    if (-not $assignments) {
        throw 'Nothing to change: pass at least one setting.'
    }

    $parameters = @{ updated_at = Get-Date | ConvertTo-FathomSqlTime }
    foreach ($name in $columns.Keys | Where-Object { $PSBoundParameters.ContainsKey($_) }) {
        $value = $PSBoundParameters[$name]
        $parameters[$columns[$name]] = if ($value -is [string] -and -not $value) { [DBNull]::Value } else { $value }
    }

    if ($PSCmdlet.ShouldProcess('Fathom directory settings', "Set $($assignments -join ', ')")) {
        # Column names come from the fixed map above, never from input; values are parameters.
        $query = "UPDATE ad_settings SET $($assignments -join ', '), updated_at = @updated_at::timestamp WHERE id = 1"
        $null = Invoke-FathomSql -Query $query -Parameters $parameters
    }
    Get-FathomDirectorySetting
}
