function Get-FathomDirectorySetting {
    <#
    .SYNOPSIS
        The directory lookup settings: whether lookups run, which server to ask, how often to refresh.
    #>
    [CmdletBinding()]
    [OutputType('Fathom.DirectorySetting')]
    param()

    $row = Invoke-FathomQuery -Query 'SELECT * FROM ad_settings WHERE id = 1'
    [pscustomobject] @{
        PSTypeName   = 'Fathom.DirectorySetting'
        Enabled      = $row.enabled
        Server       = $row.server
        RefreshHours = $row.refresh_hours
        UpdatedAt    = $row.updated_at
    }
}
