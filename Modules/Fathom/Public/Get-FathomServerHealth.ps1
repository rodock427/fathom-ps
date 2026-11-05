function Get-FathomServerHealth {
    <#
    .SYNOPSIS
        One health line per monitored server: overall status, poll and log freshness, and the usage source in effect.
    .DESCRIPTION
        Status is the first that applies: Disabled, Down (lmstat failed or timed out), Degraded
        (a vendor daemon is down), Stale (no fresh poll, or a log that stopped while seats are
        in use), Drifted (the log's seat count disagrees with lmstat), Unknown (never
        collected), Healthy.

        EffectiveSource is where usage history comes from: log, lmstat, or auto (per time
        bucket, the log where it has coverage and lmstat to fill its gaps, such as while a log
        share was unreachable). A log imported as history counts as a source. Usage source
        Auto resolves to auto when the server has both
        sources, but to lmstat while the log's count has drifted, because then none of its
        numbers can be trusted. Log and Lmstat force one.
    .EXAMPLE
        Get-FathomServerHealth | Where-Object Status -NE 'Healthy'
    #>
    [CmdletBinding()]
    [OutputType('Fathom.ServerHealth')]
    param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [string] $ServerId,

        # A poll older than this is stale. The schedule polls every 5 minutes.
        [ValidateRange(1, 1440)]
        [int] $PollStaleMinutes = 15,

        # A log with no new lines for this long, while lmstat shows seats in use, has likely stopped.
        [ValidateRange(1, 10080)]
        [int] $LogStaleMinutes = 120,

        # Seats by which the log's running count may differ from lmstat before the log is
        # distrusted. Some slack covers the minute between a log read and a poll.
        [ValidateRange(0, 1000)]
        [int] $DriftTolerance = 2
    )

    process {
        $query = @'
SELECT s.server_id, s.name, s.enabled, s.license_spec, s.log_path, s.usage_source,
       s.last_polled_at, s.last_poll_status, s.last_poll_message, s.poll_minutes,
       EXISTS (SELECT 1 FROM log_coverage c WHERE c.server_id = s.server_id) AS has_log_history,
       s.last_log_read_at, s.last_log_status, s.last_log_error,
       -- Before log health was recorded, the newest stored event is the best evidence.
       COALESCE(s.last_log_line_at, (SELECT MAX(timestamp) FROM license_events e WHERE e.server_id = s.server_id)) AS last_log_line_at,
       (SELECT COALESCE(SUM(licenses_in_use), 0) FROM live_status l
         WHERE l.server_id = s.server_id AND l.captured_at = s.last_polled_at) AS seats_in_use,
       (SELECT string_agg(daemon, ', ' ORDER BY daemon) FROM vendor_daemon_status d
         WHERE d.server_id = s.server_id AND NOT d.up) AS daemons_down,
       (SELECT COUNT(*) FROM license_events e
         WHERE e.server_id = s.server_id AND e.event_type = 'unsupported' AND e.timestamp >= @week_ago::timestamp) AS unparsed_lines,
       -- Seats in use by the log's running count vs the latest lmstat reading, per feature.
       -- Missing lines make them disagree. A restart frees every seat, so only events since count.
       (SELECT SUM(ABS(COALESCE(lg.in_use, 0) - l.licenses_in_use))
          FROM live_status l
          LEFT JOIN (SELECT feature, SUM(CASE event_type WHEN 'checkout' THEN unit_count ELSE -unit_count END) AS in_use
                       FROM license_events e
                       LEFT JOIN (SELECT vendor_daemon, MAX(timestamp) AS restarted FROM license_events r
                                   WHERE r.server_id = s.server_id AND r.event_type IN ('vendor_daemon_up', 'vendor_daemon_down')
                                   GROUP BY 1) v ON v.vendor_daemon = e.vendor_daemon
                      WHERE e.server_id = s.server_id AND e.event_type IN ('checkout', 'checkin')
                        AND e.timestamp >= COALESCE(v.restarted, '-infinity')
                        AND e.timestamp >= COALESCE((SELECT MAX(r.timestamp) FROM license_events r
                                                      WHERE r.server_id = s.server_id AND r.event_type IN ('server_up', 'server_down')),
                                                    '-infinity')
                      GROUP BY feature) lg ON lg.feature = l.feature
         WHERE l.server_id = s.server_id AND l.captured_at = s.last_polled_at
           AND EXISTS (SELECT 1 FROM license_events e WHERE e.server_id = s.server_id)) AS log_drift
FROM monitored_servers s
WHERE (@server_id::text IS NULL OR s.server_id = @server_id)
ORDER BY s.server_id
'@
        $now = Get-Date
        $parameters = @{
            server_id = if ($ServerId) { $ServerId } else { [DBNull]::Value }
            week_ago  = $now.AddDays(-7) | ConvertTo-FathomSqlTime
        }

        foreach ($row in Invoke-FathomQuery -Query $query -Parameters $parameters) {
            # Three missed polls, however often this server is polled.
            $staleAfter = [Math]::Max($PollStaleMinutes, 3 * $row.poll_minutes)
            $pollStale = $row.license_spec -and (-not $row.last_polled_at -or $row.last_polled_at -lt $now.AddMinutes(-$staleAfter))
            # Only judged against lmstat: without it, a quiet log can't be told from an idle server.
            $logQuiet = -not $row.last_log_line_at -or $row.last_log_line_at -lt $now.AddMinutes(-$LogStaleMinutes)
            $logStale = $row.log_path -and $row.license_spec -and $row.seats_in_use -gt 0 -and $logQuiet
            $drifted = $row.log_path -and -not $pollStale -and $row.log_drift -gt $DriftTolerance

            $effectiveSource = switch ($row.usage_source) {
                'log' { 'log' }
                'lmstat' { 'lmstat' }
                default {
                    if ($drifted -or -not ($row.log_path -or $row.has_log_history)) {
                        'lmstat'
                    } elseif (-not $row.license_spec) {
                        'log'
                    } else {
                        'auto'
                    }
                }
            }

            $status = if (-not $row.enabled) {
                'Disabled'
            } elseif ($row.last_poll_status -in 'Down', 'Timeout') {
                'Down'
            } elseif ($row.last_poll_status -eq 'Degraded') {
                'Degraded'
            } elseif ($pollStale -or $logStale -or ($row.log_path -and $row.last_log_status -eq 'Unreachable')) {
                'Stale'
            } elseif ($drifted) {
                'Drifted'
            } elseif (-not $row.last_polled_at -and -not $row.last_log_read_at) {
                'Unknown'
            } else {
                'Healthy'
            }

            [pscustomobject] @{
                PSTypeName      = 'Fathom.ServerHealth'
                ServerId        = $row.server_id
                Name            = $row.name
                Status          = $status
                PollStatus      = $row.last_poll_status
                PollMessage     = $row.last_poll_message
                LastPolled      = $row.last_polled_at
                PollStale       = [bool] $pollStale
                DaemonsDown     = $row.daemons_down
                SeatsInUse      = [int] $row.seats_in_use
                LogStatus       = $row.last_log_status
                LogError        = $row.last_log_error
                LastLogLine     = $row.last_log_line_at
                LogStale        = [bool] $logStale
                LogDrift        = $row.log_drift
                LogDrifted      = [bool] $drifted
                UnparsedLines   = [int] $row.unparsed_lines
                UsageSource     = $row.usage_source
                EffectiveSource = $effectiveSource
                HasLogHistory   = [bool] ($row.log_path -or $row.has_log_history)
            }
        }
    }
}
