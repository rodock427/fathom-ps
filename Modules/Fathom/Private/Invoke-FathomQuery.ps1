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

    # Rows are DataRows: copy just the result columns. PSObject.Properties would also copy the
    # row's own members (Table, ItemArray, RowState...), costing time and memory on big results.
    $columns = @($rows | Select-Object -First 1).ForEach({ $_.Table.Columns.ColumnName })
    foreach ($row in $rows) {
        $record = [ordered] @{}
        foreach ($column in $columns) {
            $value = $row[$column]
            $record[$column] = if ($value -is [DBNull]) { $null } else { $value }
        }
        [pscustomobject] $record
    }
}
