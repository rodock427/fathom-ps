function Invoke-FathomSql {
    <#
    .SYNOPSIS
        Runs statements that return no rows (INSERT, UPDATE, DDL) and returns the rows affected.
    .DESCRIPTION
        A failure throws and stops the caller, whatever its ErrorAction: a failed write must
        never be followed by the next one.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string] $Query,
        [hashtable] $Parameters = @{},
        [int] $CommandTimeout = 30
    )

    $command = New-FathomCommand -Query $Query -Parameters $Parameters -CommandTimeout $CommandTimeout
    try {
        $command.ExecuteNonQuery()
    } catch {
        throw
    } finally {
        $command.Dispose()
    }
}
