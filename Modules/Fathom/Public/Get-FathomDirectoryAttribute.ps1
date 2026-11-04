function Get-FathomDirectoryAttribute {
    <#
    .SYNOPSIS
        Every attribute the directory has returned, and whether its values are recorded and shown.
    .EXAMPLE
        Get-FathomDirectoryAttribute -Kind user | Where-Object Shown
    #>
    [CmdletBinding()]
    [OutputType('Fathom.DirectoryAttribute')]
    param(
        [ValidateSet('user', 'computer')]
        [string] $Kind
    )

    $query = 'SELECT * FROM ad_attributes WHERE (@kind::text IS NULL OR kind = @kind) ORDER BY kind DESC, lower(name)'
    foreach ($row in Invoke-FathomQuery -Query $query -Parameters @{ kind = $Kind ? $Kind : [DBNull]::Value }) {
        [pscustomobject] @{
            PSTypeName = 'Fathom.DirectoryAttribute'
            Kind       = $row.kind
            Name       = $row.name
            Recorded   = $row.recorded
            Shown      = $row.shown
            FirstSeen  = $row.first_seen_at
        }
    }
}
