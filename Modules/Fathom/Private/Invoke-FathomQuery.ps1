function Invoke-FathomQuery {
    <#
    .SYNOPSIS
        Runs a SELECT on this runspace's connection and returns plain objects, with NULL as $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Query,
        [hashtable] $Parameters = @{},
        [int] $CommandTimeout = 30
    )

    $command = New-FathomCommand -Query $Query -Parameters $Parameters -CommandTimeout $CommandTimeout
    try {
        $reader = $command.ExecuteReader()
        try {
            $columns = @(for ($i = 0; $i -lt $reader.FieldCount; $i++) { $reader.GetName($i) })
            while ($reader.Read()) {
                $record = [ordered] @{}
                for ($i = 0; $i -lt $columns.Count; $i++) {
                    $record[$columns[$i]] = ConvertFrom-FathomDbValue -Value $reader.GetValue($i)
                }
                [pscustomobject] $record
            }
        } finally {
            $reader.Dispose()
        }
    } catch {
        throw
    } finally {
        $command.Dispose()
    }
}
