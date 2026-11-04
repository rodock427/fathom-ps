function Get-FathomSeriesSql {
    <#
    .SYNOPSIS
        SQL (a CTE list ending in "series") for one server's peak seats in use per time bucket.
    .DESCRIPTION
        series(feature, bucket, peak_in_use, issued). Parameters: @server_id, @from, @to,
        @step_minutes, @all_features, @features. Callers append their own final SELECT.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('log', 'lmstat')]
        [string] $Source
    )

    # Seats issued per bucket come from lmstat when it has a sample, else the latest known count.
    $issued = @'
issued_per_bucket AS (
    SELECT feature, date_bin(make_interval(mins => @step_minutes), captured_at, @from::timestamp) AS bucket,
           MAX(licenses_issued) AS issued
    FROM usage_samples
    WHERE server_id = @server_id AND captured_at >= @from::timestamp AND captured_at < @to::timestamp
    GROUP BY 1, 2
)
'@

    if ($Source -eq 'lmstat') {
        # Each 5-minute snapshot is a direct reading; a bucket with none has no data (a gap).
        return @"
WITH $issued,
series AS (
    SELECT feature, date_bin(make_interval(mins => @step_minutes), captured_at, @from::timestamp) AS bucket,
           MAX(licenses_in_use) AS peak_in_use, MAX(licenses_issued) AS issued
    FROM usage_samples
    WHERE server_id = @server_id AND captured_at >= @from::timestamp AND captured_at < @to::timestamp
      AND (@all_features OR feature = ANY(@features))
    GROUP BY 1, 2
)
"@
    }

    # From the debug log: seats in use is a running sum of checkouts (+units) and checkins
    # (-units), Fathom's definition exactly: checkins first at a shared second, and seats held
    # from before @from carried in. It drifts if lines go missing or lmgrd restarts with seats
    # out; Get-FathomServerHealth compares it with lmstat and falls back when it does.
    @"
WITH $issued,
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
    SELECT feature, date_bin(make_interval(mins => @step_minutes), ts, @from::timestamp) AS bucket,
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
series AS (
    SELECT l.feature, l.bucket,
           GREATEST(COALESCE(LAG(l.closing) OVER (PARTITION BY l.feature ORDER BY l.bucket), c.in_use, 0),
                    COALESCE(l.max_in, 0)) AS peak_in_use,
           COALESCE(ib.issued, fi.licenses_issued) AS issued
    FROM levels l
    LEFT JOIN carried_in c ON c.feature = l.feature
    LEFT JOIN issued_per_bucket ib ON ib.feature = l.feature AND ib.bucket = l.bucket
    LEFT JOIN feature_inventory fi ON fi.server_id = @server_id AND fi.feature = l.feature
)
"@
}
