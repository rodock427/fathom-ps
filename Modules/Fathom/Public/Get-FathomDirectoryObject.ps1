function Get-FathomDirectoryObject {
    <#
    .SYNOPSIS
        What the directory says about FlexLM users or hosts: the shown attributes, or every recorded one.
    .DESCRIPTION
        Individual data: Operator tier. Names are matched as the directory tables key them (case
        ignored, a host without its domain). Names never looked up are left out.
    .EXAMPLE
        Get-FathomDirectoryObject -Kind user -Name dave
    #>
    [CmdletBinding()]
    [OutputType('Fathom.DirectoryObject')]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('user', 'computer')]
        [string] $Kind,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Name,

        # Every recorded attribute, not only the shown ones.
        [switch] $All
    )

    $keys = @($Name | Where-Object { $_ } | Get-FathomDirectoryKey -Kind $Kind | Select-Object -Unique)
    if (-not $keys) {
        return
    }
    $wanted = @(Get-FathomDirectoryAttribute -Kind $Kind | Where-Object { $All ? $_.Recorded : $_.Shown } | ForEach-Object Name)

    $query = 'SELECT name, found, attributes::text AS attributes, fetched_at FROM ad_objects WHERE kind = @kind AND name = ANY(@names)'
    foreach ($row in Invoke-FathomQuery -Query $query -Parameters @{ kind = $Kind; names = [string[]] $keys }) {
        $stored = $row.attributes | ConvertFrom-Json -AsHashtable
        $attributes = [ordered] @{}
        foreach ($attribute in $wanted | Where-Object { $stored.ContainsKey($_) }) {
            $attributes[$attribute] = $stored[$attribute]
        }
        [pscustomobject] @{
            PSTypeName = 'Fathom.DirectoryObject'
            Kind       = $Kind
            Name       = $row.name
            Found      = $row.found
            Attributes = $attributes
            FetchedAt  = $row.fetched_at
        }
    }
}
