function Get-FathomServerUptime {
    <#
    .SYNOPSIS
        Share of lmstat polls in a period that found each server up, and its longest outage.
    .DESCRIPTION
        Degraded counts as up here: lmgrd answered, though a vendor daemon may not have. Servers
        monitored by log only have no polls, so they don't appear.
    .EXAMPLE
        Get-FathomServerUptime -From (Get-Date).AddDays(-30)
    #>
    [CmdletBinding()]
    [OutputType('Fathom.Uptime')]
    param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [string] $ServerId,

        [datetime] $From = (Get-Date).AddDays(-30),

        [datetime] $To = (Get-Date)
    )

    process {
        # Consecutive failed polls form one outage, measured from its first failure to the next good poll.
        $query = @'
WITH polls AS (
    SELECT server_id, polled_at, status IN ('Up', 'Degraded') AS up,
           LEAD(polled_at) OVER (PARTITION BY server_id ORDER BY polled_at) AS next_poll
    FROM poll_history
    WHERE polled_at >= @from::timestamp AND polled_at < @to::timestamp
      AND (@server_id::text IS NULL OR server_id = @server_id)
),
runs AS (
    SELECT *, SUM(CASE WHEN up THEN 1 ELSE 0 END) OVER (PARTITION BY server_id ORDER BY polled_at) AS run
    FROM polls
),
outages AS (
    SELECT server_id, MIN(polled_at) AS began, MAX(polled_at) AS last_down
    FROM runs WHERE NOT up
    GROUP BY server_id, run
),
spans AS (
    SELECT o.server_id, o.began, COALESCE(n.recovered, @to::timestamp) AS ended
    FROM outages o
    LEFT JOIN LATERAL (
        SELECT MIN(p.polled_at) AS recovered FROM polls p
        WHERE p.server_id = o.server_id AND p.up AND p.polled_at > o.last_down
    ) n ON TRUE
)
SELECT p.server_id, COUNT(*) AS polls, AVG(p.up::int) AS up_share,
       (SELECT MAX(ended - began) FROM spans o WHERE o.server_id = p.server_id) AS longest_outage,
       (SELECT COUNT(*) FROM spans o WHERE o.server_id = p.server_id) AS outages
FROM polls p
GROUP BY p.server_id
ORDER BY p.server_id
'@
        $parameters = @{
            server_id = if ($ServerId) { $ServerId } else { [DBNull]::Value }
            from      = $From | ConvertTo-FathomSqlTime
            to        = $To | ConvertTo-FathomSqlTime
        }

        foreach ($row in Invoke-FathomQuery -Query $query -Parameters $parameters) {
            [pscustomobject] @{
                PSTypeName    = 'Fathom.Uptime'
                ServerId      = $row.server_id
                Polls         = [int] $row.polls
                UptimePercent = [Math]::Round(100 * [double] $row.up_share, 2)
                Outages       = [int] $row.outages
                LongestOutage = $row.longest_outage
            }
        }
    }
}
