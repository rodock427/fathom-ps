function Invoke-FathomQuery {
    <#
    .SYNOPSIS
        Runs a SELECT on the Fathom connection and returns plain objects, with NULL as $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Query,
        [hashtable] $Parameters = @{}
    )

    # SimplySql warns on an empty result set; for us that is a normal answer.
    $rows = Invoke-SqlQuery -ConnectionName $script:ConnectionName -Query $Query -Parameters $Parameters -WarningAction SilentlyContinue

    foreach ($row in $rows) {
        $record = [ordered] @{}
        foreach ($property in $row.PSObject.Properties) {
            $record[$property.Name] = if ($property.Value -is [DBNull]) { $null } else { $property.Value }
        }
        [pscustomobject] $record
    }
}
