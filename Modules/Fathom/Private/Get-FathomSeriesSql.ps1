function Get-FathomSeriesSql {
    <#
    .SYNOPSIS
        SQL (a CTE list ending in "series") for one server's peak seats in use per time bucket.
    .DESCRIPTION
        series(feature, bucket, peak_in_use, issued, source). Parameters: @server_id, @from,
        @to, @step_minutes, @all_features, @features. Callers append their own final SELECT.

        auto picks per bucket: the debug log where it covers that time, else the lmstat
        reading, else nothing (a gap, never a made-up zero).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('log', 'lmstat', 'auto')]
        [string] $Source
    )

    # The start of the @step_minutes bucket a time falls in, counted from @from.
    # Plain interval arithmetic, so it works on any supported Postgres version.
    $bucketOf = {
        param([string] $Column)
        "(@from::timestamp + make_interval(mins => @step_minutes) * floor(extract(epoch FROM ($Column - @from::timestamp)) / (@step_minutes * 60)))"
    }

    # Each 5-minute lmstat snapshot is a direct reading.
    $lmstat = @"
lmstat_series AS (
    SELECT feature, $(& $bucketOf 'captured_at') AS bucket,
           MAX(licenses_in_use) AS peak_in_use, MAX(licenses_issued) AS issued
    FROM usage_samples
    WHERE server_id = @server_id AND captured_at >= @from::timestamp AND captured_at < @to::timestamp
      AND (@all_features OR feature = ANY(@features))
    GROUP BY 1, 2
)
"@

    # From the debug log: seats in use is a running sum of checkouts (+units) and checkins
    # (-units), Fathom's definition exactly: checkins first at a shared second, and seats held
    # from before @from carried in. It drifts if lines go missing or lmgrd restarts with seats
    # out; Get-FathomServerHealth compares it with lmstat and stops trusting it when it does.
    $log = @"
changes AS (
    SELECT feature, timestamp AS ts,
           CASE event_type WHEN 'checkout' THEN unit_count ELSE -unit_count END AS delta
    FROM license_events
    WHERE server_id = @server_id AND event_type IN ('checkout', 'checkin') AND timestamp < @to::timestamp
      AND (@all_features OR feature = ANY(@features))
),
features AS (SELECT DISTINCT feature FROM changes),
running AS (
    SELECT feature, ts, delta,
           SUM(delta) OVER (PARTITION BY feature ORDER BY ts, delta ROWS UNBOUNDED PRECEDING) AS in_use
    FROM changes
),
carried_in AS (
    SELECT DISTINCT ON (feature) feature, in_use
    FROM running WHERE ts < @from::timestamp
    ORDER BY feature, ts DESC, delta DESC
),
buckets AS (
    -- Every bucket that starts before @to; the last may run past it (events stop at @to).
    SELECT generate_series(@from::timestamp, @to::timestamp - interval '1 second',
                           make_interval(mins => @step_minutes)) AS bucket
),
in_bucket AS (
    SELECT feature, $(& $bucketOf 'ts') AS bucket,
           MAX(in_use) AS max_in,
           (ARRAY_AGG(in_use ORDER BY ts DESC, delta DESC))[1] AS last_in
    FROM running WHERE ts >= @from::timestamp
    GROUP BY 1, 2
),
-- Carry each bucket's closing level forward through buckets with no events.
grid AS (
    SELECT f.feature, b.bucket, i.max_in, i.last_in,
           COUNT(i.last_in) OVER (PARTITION BY f.feature ORDER BY b.bucket) AS run
    FROM features f CROSS JOIN buckets b
    LEFT JOIN in_bucket i ON i.feature = f.feature AND i.bucket = b.bucket
),
levels AS (
    SELECT feature, bucket, max_in,
           FIRST_VALUE(last_in) OVER (PARTITION BY feature, run ORDER BY bucket) AS closing
    FROM grid
),
log_series AS (
    SELECT l.feature, l.bucket,
           GREATEST(COALESCE(LAG(l.closing) OVER (PARTITION BY l.feature ORDER BY l.bucket), c.in_use, 0),
                    COALESCE(l.max_in, 0)) AS peak_in_use
    FROM levels l
    LEFT JOIN carried_in c ON c.feature = l.feature
)
"@

    $final = switch ($Source) {
        'lmstat' {
            "series AS (SELECT feature, bucket, peak_in_use, issued, 'lmstat' AS source FROM lmstat_series)"
        }
        'log' {
            @'
series AS (
    SELECT l.feature, l.bucket, l.peak_in_use, COALESCE(m.issued, fi.licenses_issued) AS issued, 'log' AS source
    FROM log_series l
    LEFT JOIN lmstat_series m ON m.feature = l.feature AND m.bucket = l.bucket
    LEFT JOIN feature_inventory fi ON fi.server_id = @server_id AND fi.feature = l.feature
)
'@
        }
        'auto' {
            @'
-- A bucket is covered when a log file's recorded span overlaps it. History ingested before
-- coverage was recorded (earlier versions, or Python Fathom) is trusted from the server's
-- first log event up to its first recorded span; before any log event there's no log data.
covered AS (
    SELECT b.bucket,
           EXISTS (SELECT 1 FROM log_coverage c
                    WHERE c.server_id = @server_id
                      AND c.first_event_at < b.bucket + make_interval(mins => @step_minutes)
                      AND c.last_event_at >= b.bucket)
           OR (b.bucket + make_interval(mins => @step_minutes) >
                   (SELECT MIN(timestamp) FROM license_events
                     WHERE server_id = @server_id AND event_type IN ('checkout', 'checkin'))
               AND b.bucket < COALESCE((SELECT MIN(first_event_at) FROM log_coverage WHERE server_id = @server_id),
                                       'infinity'::timestamp)) AS by_log
    FROM buckets b
),
picked AS (
    SELECT COALESCE(l.feature, m.feature) AS feature, COALESCE(l.bucket, m.bucket) AS bucket,
           CASE WHEN l.bucket IS NOT NULL AND cv.by_log THEN 'log'
                WHEN m.bucket IS NOT NULL THEN 'lmstat' END AS source,
           l.peak_in_use AS log_peak, m.peak_in_use AS lmstat_peak, m.issued AS lmstat_issued
    FROM log_series l
    FULL JOIN lmstat_series m ON m.feature = l.feature AND m.bucket = l.bucket
    LEFT JOIN covered cv ON cv.bucket = COALESCE(l.bucket, m.bucket)
),
series AS (
    SELECT p.feature, p.bucket,
           CASE p.source WHEN 'log' THEN p.log_peak ELSE p.lmstat_peak END AS peak_in_use,
           COALESCE(p.lmstat_issued, fi.licenses_issued) AS issued, p.source
    FROM picked p
    LEFT JOIN feature_inventory fi ON fi.server_id = @server_id AND fi.feature = p.feature
    WHERE p.source IS NOT NULL
)
'@
        }
    }

    $ctes = if ($Source -eq 'lmstat') { $lmstat } else { "$lmstat,`n$log" }
    "WITH $ctes,`n$final`n"
}
