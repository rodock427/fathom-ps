function Get-FathomTopUser {
    <#
    .SYNOPSIS
        The people who used licenses most in a period: hours held, checkouts and denials. Individual data: Operator tier.
    .DESCRIPTION
        Hours come from whichever source saw more of a person's use of a feature: checkouts paired
        with their checkins in the debug log, or sessions seen by lmstat. A checkout with no checkin
        adds no hours, so log hours can run short but never long.
    .EXAMPLE
        Get-FathomTopUser -From (Get-Date).AddDays(-30) -Top 10
    #>
    [CmdletBinding()]
    [OutputType('Fathom.TopUser')]
    param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [string] $ServerId,

        [string] $Feature,

        [datetime] $From = (Get-Date).AddDays(-30),

        [datetime] $To = (Get-Date),

        [ValidateRange(1, 10000)]
        [int] $Top = 25
    )

    process {
        if ($To -le $From) {
            throw '-To must be later than -From.'
        }

        $query = @'
WITH events AS (
    SELECT * FROM license_events
    WHERE "user" <> '' AND timestamp >= @from::timestamp AND timestamp < @to::timestamp
      AND (@server_id::text IS NULL OR server_id = @server_id)
      AND (@feature::text IS NULL OR feature = @feature)
),
paired AS (
    SELECT server_id, feature, "user", event_type, timestamp,
           LEAD(timestamp) OVER seat AS next_at, LEAD(event_type) OVER seat AS next_type
    FROM events
    WHERE event_type IN ('checkout', 'checkin')
    WINDOW seat AS (PARTITION BY server_id, feature, "user", host ORDER BY timestamp)
),
log_use AS (
    SELECT server_id, feature, fathom_person("user") AS person,
           COUNT(*) FILTER (WHERE event_type = 'checkout') AS checkouts,
           COALESCE(SUM(EXTRACT(EPOCH FROM next_at - timestamp)) FILTER (WHERE event_type = 'checkout' AND next_type = 'checkin'), 0) AS seconds
    FROM paired GROUP BY 1, 2, 3
),
lmstat_use AS (
    SELECT server_id, feature, fathom_person("user") AS person,
           SUM(EXTRACT(EPOCH FROM LEAST(last_seen_at, @to::timestamp) - GREATEST(started_at, @from::timestamp))) AS seconds
    FROM observed_sessions
    WHERE first_seen_at < @to::timestamp AND last_seen_at >= @from::timestamp
      AND (@server_id::text IS NULL OR server_id = @server_id)
      AND (@feature::text IS NULL OR feature = @feature)
    GROUP BY 1, 2, 3
),
denials AS (
    SELECT server_id, feature, fathom_person("user") AS person, SUM(unit_count) AS denials
    FROM events WHERE event_type = 'denied' GROUP BY 1, 2, 3
),
merged AS (
    SELECT person, feature, COALESCE(l.checkouts, 0) AS checkouts,
           GREATEST(l.seconds, s.seconds, 0) AS seconds, COALESCE(d.denials, 0) AS denials
    FROM log_use l
    FULL JOIN lmstat_use s USING (server_id, feature, person)
    FULL JOIN denials d USING (server_id, feature, person)
)
SELECT person, COUNT(DISTINCT feature) AS features, SUM(checkouts) AS checkouts,
       SUM(seconds) / 3600 AS hours, SUM(denials) AS denials
FROM merged
GROUP BY person
ORDER BY hours DESC, checkouts DESC, person
LIMIT @top
'@
        $parameters = @{
            server_id = if ($ServerId) { $ServerId } else { [DBNull]::Value }
            feature   = if ($Feature) { $Feature } else { [DBNull]::Value }
            from      = $From | ConvertTo-FathomSqlTime
            to        = $To | ConvertTo-FathomSqlTime
            top       = $Top
        }

        foreach ($row in Invoke-FathomQuery -Query $query -Parameters $parameters) {
            [pscustomobject] @{
                PSTypeName = 'Fathom.TopUser'
                User       = $row.person
                Features   = [int] $row.features
                Hours      = [Math]::Round([double] $row.hours, 1)
                Checkouts  = [int] $row.checkouts
                Denials    = [int] $row.denials
            }
        }
    }
}
