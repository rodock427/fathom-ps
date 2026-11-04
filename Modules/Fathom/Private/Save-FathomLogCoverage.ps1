function Save-FathomLogCoverage {
    <#
    .SYNOPSIS
        Widens a log file's recorded time span to include a chunk's events. Call inside the chunk's transaction.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $FileKey,
        [Parameter(Mandatory)] [string] $ServerId,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $InputObject
    )

    $times = $InputObject.Timestamp | Measure-Object -Minimum -Maximum
    if (-not $times.Count) {
        return
    }

    $query = @'
INSERT INTO log_coverage (file_key, server_id, first_event_at, last_event_at)
VALUES (@file_key, @server_id, @first::timestamp, @last::timestamp)
ON CONFLICT (file_key) DO UPDATE SET
    first_event_at = LEAST(log_coverage.first_event_at, EXCLUDED.first_event_at),
    last_event_at = GREATEST(log_coverage.last_event_at, EXCLUDED.last_event_at)
'@
    $parameters = @{
        file_key  = $FileKey
        server_id = $ServerId
        first     = $times.Minimum | ConvertTo-FathomSqlTime
        last      = $times.Maximum | ConvertTo-FathomSqlTime
    }
    $null = Invoke-SqlUpdate -ConnectionName $script:ConnectionName -Query $query -Parameters $parameters
}
