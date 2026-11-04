function Get-FathomCapacityReport {
    <#
    .SYNOPSIS
        Renewal numbers per feature: seats, peak and typical use, time at capacity, denials, active users.
    .DESCRIPTION
        Peak, 95th percentile and time at capacity come from each server's effective usage
        source, over 5-minute intervals by default. Denials need the debug log: a server
        without one reports them as $null (unknown), never 0. A feature is Underused when its
        peak stays below -UnderusedBelow of its seats for the whole period.
    .EXAMPLE
        Get-FathomCapacityReport -From (Get-Date).AddMonths(-3) | Where-Object Underused
    #>
    [CmdletBinding()]
    [OutputType('Fathom.CapacityRow')]
    param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [string] $ServerId,

        [datetime] $From = (Get-Date).AddDays(-30),

        [datetime] $To = (Get-Date),

        [ValidateRange(1, 1440)]
        [int] $IntervalMinutes = 5,

        # Fraction of seats the peak must reach for a feature to count as used enough.
        [ValidateRange(0.0, 1.0)]
        [double] $UnderusedBelow = 0.5
    )

    process {
        if ($To -le $From) {
            throw '-To must be later than -From.'
        }

        foreach ($server in Get-FathomServerHealth -ServerId $ServerId | Where-Object Status -NE 'Disabled') {
            $source = $server.EffectiveSource
            $hasLog = [bool] (Get-FathomServer -ServerId $server.ServerId).LogPath

            # Active users come from the same source as the usage numbers.
            $activeUsers = if ($source -eq 'log') {
                'SELECT feature, COUNT(DISTINCT "user") AS n FROM license_events WHERE server_id = @server_id AND event_type = ''checkout'' AND timestamp >= @from::timestamp AND timestamp < @to::timestamp GROUP BY feature'
            } else {
                'SELECT feature, COUNT(DISTINCT "user") AS n FROM observed_sessions WHERE server_id = @server_id AND first_seen_at < @to::timestamp AND last_seen_at >= @from::timestamp GROUP BY feature'
            }

            $query = (Get-FathomSeriesSql -Source $source) + @"
, usage AS (
    SELECT feature, MAX(peak_in_use) AS peak,
           percentile_cont(0.95) WITHIN GROUP (ORDER BY peak_in_use) AS p95,
           AVG(CASE WHEN issued > 0 THEN (peak_in_use >= issued)::int END) AS at_capacity,
           COUNT(*) AS intervals
    FROM series GROUP BY feature
),
demand AS (
    SELECT feature,
           SUM(unit_count) FILTER (WHERE event_type = 'checkout') AS checkouts,
           SUM(unit_count) FILTER (WHERE event_type = 'denied') AS denials,
           COUNT(DISTINCT "user") FILTER (WHERE event_type = 'denied') AS denied_users
    FROM license_events
    WHERE server_id = @server_id AND event_type IN ('checkout', 'denied')
      AND timestamp >= @from::timestamp AND timestamp < @to::timestamp
    GROUP BY feature
),
active AS ($activeUsers)
SELECT u.feature, fi.licenses_issued AS seats, u.peak, u.p95, u.at_capacity, u.intervals,
       COALESCE(d.checkouts, 0) AS checkouts, COALESCE(d.denials, 0) AS denials,
       COALESCE(d.denied_users, 0) AS denied_users, COALESCE(a.n, 0) AS active_users
FROM usage u
LEFT JOIN feature_inventory fi ON fi.server_id = @server_id AND fi.feature = u.feature
LEFT JOIN demand d ON d.feature = u.feature
LEFT JOIN active a ON a.feature = u.feature
ORDER BY u.feature
"@
            $parameters = @{
                server_id    = $server.ServerId
                from         = $From | ConvertTo-FathomSqlTime
                to           = $To | ConvertTo-FathomSqlTime
                step_minutes = $IntervalMinutes
                all_features = $true
                features     = [string[]] @()
            }

            foreach ($row in Invoke-FathomQuery -Query $query -Parameters $parameters) {
                $denials = if ($hasLog) { [int] $row.denials } else { $null }
                $checkouts = if ($hasLog) { [int] $row.checkouts } else { $null }
                [pscustomobject] @{
                    PSTypeName        = 'Fathom.CapacityRow'
                    ServerId          = $server.ServerId
                    Feature           = $row.feature
                    Source            = $source
                    Seats             = $row.seats
                    Peak              = [int] $row.peak
                    P95               = [Math]::Round([double] $row.p95, 1)
                    AtCapacityPercent = if ($null -ne $row.at_capacity) { [Math]::Round(100 * [double] $row.at_capacity, 1) } else { $null }
                    Checkouts         = $checkouts
                    Denials           = $denials
                    DenialRate        = if ($hasLog -and ($checkouts + $denials)) { [Math]::Round($denials / ($checkouts + $denials), 4) } else { $null }
                    DeniedUsers       = if ($hasLog) { [int] $row.denied_users } else { $null }
                    ActiveUsers       = [int] $row.active_users
                    Underused         = [bool] ($row.seats -and $row.peak -lt $UnderusedBelow * $row.seats)
                }
            }
        }
    }
}
