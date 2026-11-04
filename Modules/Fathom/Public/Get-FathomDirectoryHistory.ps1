function Get-FathomDirectoryHistory {
    <#
    .SYNOPSIS
        How a user's or host's Active Directory values changed over time, one line per changed
        attribute: the shown attributes, or every recorded one. Individual data: Operator tier.
    .EXAMPLE
        Get-FathomDirectoryHistory -Kind user -Name dave
    #>
    [CmdletBinding()]
    [OutputType('Fathom.DirectoryChange')]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('user', 'computer')]
        [string] $Kind,

        [Parameter(Mandatory)]
        [string] $Name,

        # Every recorded attribute, not only the shown ones.
        [switch] $All
    )

    $key = Get-FathomDirectoryKey -Kind $Kind -Name $Name
    $wanted = @(Get-FathomDirectoryAttribute -Kind $Kind | Where-Object { $All ? $_.Recorded : $_.Shown }).Name
    $query = 'SELECT attributes::text AS attributes, changed_at FROM ad_history WHERE kind = @kind AND name = @name ORDER BY changed_at'

    $before = @{}
    foreach ($row in Invoke-FathomQuery -Query $query -Parameters @{ kind = $Kind; name = $key }) {
        $now = $row.attributes | ConvertFrom-Json -AsHashtable
        foreach ($attribute in $wanted) {
            $old = $before[$attribute]
            $new = $now[$attribute]
            if (($old | ConvertTo-Json -Compress -Depth 4) -ne ($new | ConvertTo-Json -Compress -Depth 4)) {
                [pscustomobject] @{
                    PSTypeName = 'Fathom.DirectoryChange'
                    Time       = $row.changed_at
                    Attribute  = $attribute
                    From       = $old
                    To         = $new
                }
            }
        }
        $before = $now
    }
}
