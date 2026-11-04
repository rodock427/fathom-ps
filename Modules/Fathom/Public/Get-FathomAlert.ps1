function Get-FathomAlert {
    <#
    .SYNOPSIS
        The alerts in effect right now. Read-only: Send-FathomAlert records and mails them.
    .DESCRIPTION
        Rules, with thresholds from Get-FathomAlertSetting:
          ServerDown   lmstat has failed for at least DownMinutes (Critical)
          DaemonDown   a vendor daemon has been down for at least DownMinutes (Warning)
          AtCapacity   every seat of a feature taken for at least CapacityMinutes (Warning)
          Expiring     a license expires within ExpiryDays (Info; Warning inside 7 days; Critical once expired)
          Stale        no fresh poll, a log gone quiet while seats are in use, or an unreachable log (Warning)
          LogDrifted   the log's seat count disagrees with lmstat (Warning)
        Each alert's Key is stable while the condition lasts.
    .EXAMPLE
        Get-FathomAlert | Where-Object Severity -EQ 'Critical'
    #>
    [CmdletBinding()]
    [OutputType('Fathom.Alert')]
    param()

    $settings = Get-FathomAlertSetting
    $now = Get-Date

    # Down or degraded since the first failing poll after the last good one.
    $outageQuery = @'
SELECT s.server_id, s.last_poll_status, s.last_poll_message,
       (SELECT MIN(p.polled_at) FROM poll_history p
         WHERE p.server_id = s.server_id AND p.status <> 'Up'
           AND p.polled_at > COALESCE((SELECT MAX(u.polled_at) FROM poll_history u
                                        WHERE u.server_id = s.server_id AND u.status = 'Up'), '-infinity')) AS since
FROM monitored_servers s
WHERE s.enabled AND s.last_poll_status IN ('Down', 'Timeout', 'Degraded')
'@
    foreach ($row in Invoke-FathomQuery -Query $outageQuery) {
        $since = $row.since ?? $now
        if (($now - $since).TotalMinutes -lt $settings.DownMinutes) {
            continue
        }
        $alert = if ($row.last_poll_status -eq 'Degraded') {
            @{
                Key      = "daemon-down:$($row.server_id)"
                Rule     = 'DaemonDown'
                Severity = 'Warning'
                Message  = "Vendor daemon down on $($row.server_id): $($row.last_poll_message)"
            }
        } else {
            @{
                Key      = "server-down:$($row.server_id)"
                Rule     = 'ServerDown'
                Severity = 'Critical'
                Message  = "$($row.server_id) is not answering lmstat: $($row.last_poll_message)"
            }
        }
        ConvertTo-FathomAlert @alert -ServerId $row.server_id -Since $since
    }

    # Fully used since the first sample of the current at-capacity run, for features in the latest poll.
    $capacityQuery = @'
SELECT l.server_id, l.feature, l.licenses_issued,
       (SELECT MIN(u.captured_at) FROM usage_samples u
         WHERE u.server_id = l.server_id AND u.feature = l.feature
           AND u.captured_at > COALESCE((SELECT MAX(n.captured_at) FROM usage_samples n
                                          WHERE n.server_id = l.server_id AND n.feature = l.feature
                                            AND n.licenses_in_use < n.licenses_issued), '-infinity')) AS since
FROM live_status l
JOIN monitored_servers s ON s.server_id = l.server_id AND l.captured_at = s.last_polled_at
WHERE s.enabled AND s.last_poll_status IN ('Up', 'Degraded')
  AND l.licenses_issued > 0 AND l.licenses_in_use >= l.licenses_issued
'@
    foreach ($row in Invoke-FathomQuery -Query $capacityQuery) {
        $since = $row.since ?? $now
        if (($now - $since).TotalMinutes -ge $settings.CapacityMinutes) {
            $alert = @{
                Key      = "at-capacity:$($row.server_id):$($row.feature)"
                Rule     = 'AtCapacity'
                Severity = 'Warning'
                ServerId = $row.server_id
                Feature  = $row.feature
                Message  = "All $($row.licenses_issued) $($row.feature) seats on $($row.server_id) in use"
                Since    = $since
            }
            ConvertTo-FathomAlert @alert
        }
    }

    foreach ($expiry in Get-FathomExpiry -WithinDays $settings.ExpiryDays -IncludeExpired) {
        $date = $expiry.Expires.ToString('yyyy-MM-dd')
        $alert = @{
            # The date is part of the key, so a renewal that's about to lapse again is a new alert.
            Key      = "expiring:$($expiry.ServerId):$($expiry.Feature):$date"
            Rule     = 'Expiring'
            ServerId = $expiry.ServerId
            Feature  = $expiry.Feature
            Since    = $expiry.Expires
        }
        if ($expiry.DaysLeft -lt 0) {
            $alert.Severity = 'Critical'
            $alert.Message = "$($expiry.Feature) on $($expiry.ServerId) expired on $date"
        } else {
            $alert.Severity = if ($expiry.DaysLeft -le 7) { 'Warning' } else { 'Info' }
            $alert.Message = "$($expiry.Feature) on $($expiry.ServerId) expires on $date ($($expiry.DaysLeft) days)"
        }
        ConvertTo-FathomAlert @alert
    }

    # Down servers are already reported above; staleness on top of that is noise.
    foreach ($health in Get-FathomServerHealth | Where-Object Status -NotIn 'Disabled', 'Down') {
        $reasons = @(
            if ($health.PollStale) { "no lmstat poll since $($health.LastPolled ?? 'ever')" }
            if ($health.LogStale) { "no new log lines since $($health.LastLogLine ?? 'ever') while $($health.SeatsInUse) seats are in use" }
            if ($health.LogStatus -eq 'Unreachable') { "log unreachable: $($health.LogError)" }
        )
        if ($reasons) {
            $alert = @{
                Key      = "stale:$($health.ServerId)"
                Rule     = 'Stale'
                Severity = 'Warning'
                ServerId = $health.ServerId
                Message  = "Data from $($health.ServerId) is stale: $($reasons -join '; ')"
            }
            ConvertTo-FathomAlert @alert
        }
        # Its own flag, not Status: a degraded server's drift would otherwise go unreported.
        if ($health.LogDrifted) {
            $alert = @{
                Key      = "log-drifted:$($health.ServerId)"
                Rule     = 'LogDrifted'
                Severity = 'Warning'
                ServerId = $health.ServerId
                Message  = "The debug log for $($health.ServerId) disagrees with lmstat by $($health.LogDrift) seats; using lmstat until they agree"
            }
            ConvertTo-FathomAlert @alert
        }
    }
}
