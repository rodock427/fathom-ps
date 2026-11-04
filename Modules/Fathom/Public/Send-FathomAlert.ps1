function Send-FathomAlert {
    <#
    .SYNOPSIS
        Records the current alerts and mails one digest of what's new, still active and resolved.
    .DESCRIPTION
        Meant for a schedule. Each alert is mailed when it appears, again every RepeatHours while
        it lasts, and once when it clears. While alerts are disabled (the default) they're still
        recorded, but nothing is sent or marked as sent, so enabling them mails whatever is
        active then. A failed send is simply retried on the next run.
    .EXAMPLE
        Send-FathomAlert -Credential $FathomSmtpCredential
    .EXAMPLE
        Send-FathomAlert -Test    # check the mail settings
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Fathom.AlertRun')]
    param(
        # For an SMTP server that needs a login.
        [pscredential] $Credential,

        # Send a test message now, whether or not alerts are enabled.
        [switch] $Test
    )

    $settings = Get-FathomAlertSetting
    $mail = @{ Settings = $settings; Credential = $Credential }

    if ($Test) {
        if ($PSCmdlet.ShouldProcess(($settings.To -join ', '), 'Send test message')) {
            Send-FathomMail @mail -Subject 'Fathom: test message' -Body 'Fathom license monitoring can send you alerts.'
        }
        return
    }

    $now = Get-Date | ConvertTo-FathomSqlTime
    $active = @(Get-FathomAlert)

    Start-FathomTransaction
    try {
        # An alert that comes back after clearing starts over as new.
        $upsert = @'
INSERT INTO alert_state (alert_key, rule, severity, server_id, feature, message, condition_since, first_seen_at, last_seen_at)
VALUES (@key, @rule, @severity, @server_id, @feature, @message, @since::timestamp, @now::timestamp, @now::timestamp)
ON CONFLICT (alert_key) DO UPDATE SET
    rule = EXCLUDED.rule, severity = EXCLUDED.severity, message = EXCLUDED.message,
    condition_since = EXCLUDED.condition_since,
    last_seen_at = EXCLUDED.last_seen_at,
    first_seen_at = CASE WHEN alert_state.resolved_at IS NULL THEN alert_state.first_seen_at ELSE EXCLUDED.first_seen_at END,
    last_notified_at = CASE WHEN alert_state.resolved_at IS NULL THEN alert_state.last_notified_at END,
    resolution_notified = FALSE,
    resolved_at = NULL
'@
        foreach ($alert in $active) {
            $parameters = @{
                key       = $alert.Key
                rule      = $alert.Rule
                severity  = $alert.Severity
                server_id = $alert.ServerId ?? [DBNull]::Value
                feature   = $alert.Feature ?? [DBNull]::Value
                message   = $alert.Message
                since     = if ($alert.Since) { $alert.Since | ConvertTo-FathomSqlTime } else { [DBNull]::Value }
                now       = $now
            }
            $null = Invoke-FathomSql -Query $upsert -Parameters $parameters
        }

        $resolve = 'UPDATE alert_state SET resolved_at = @now::timestamp WHERE resolved_at IS NULL AND NOT (alert_key = ANY(@keys))'
        $null = Invoke-FathomSql -Query $resolve -Parameters @{ now = $now; keys = [string[]] @($active.Key) }
        Complete-FathomTransaction
    } catch {
        Undo-FathomTransaction
        throw
    }

    # Only alerts that were mailed get a "resolved" mail; one that came and went unseen doesn't.
    $due = @'
SELECT alert_key, severity, message, first_seen_at, resolved_at,
       -- Expiry alerts carry the expiry date as their "since"; it isn't a start time.
       CASE WHEN rule = 'Expiring' THEN first_seen_at ELSE COALESCE(condition_since, first_seen_at) END AS began,
       CASE WHEN resolved_at IS NOT NULL THEN 'resolved'
            WHEN last_notified_at IS NULL THEN 'new'
            ELSE 'reminder' END AS kind
FROM alert_state
WHERE (resolved_at IS NULL AND last_notified_at IS NULL)
   OR (resolved_at IS NULL AND @repeat_hours > 0 AND last_notified_at <= @now::timestamp - make_interval(hours => @repeat_hours))
   OR (resolved_at IS NOT NULL AND last_notified_at IS NOT NULL AND NOT resolution_notified)
ORDER BY CASE severity WHEN 'Critical' THEN 0 WHEN 'Warning' THEN 1 ELSE 2 END, first_seen_at
'@
    $pending = @(Invoke-FathomQuery -Query $due -Parameters @{ now = $now; repeat_hours = $settings.RepeatHours })

    $run = [pscustomobject] @{
        PSTypeName = 'Fathom.AlertRun'
        Active     = $active.Count
        New        = @($pending | Where-Object kind -EQ 'new').Count
        Reminders  = @($pending | Where-Object kind -EQ 'reminder').Count
        Resolved   = @($pending | Where-Object kind -EQ 'resolved').Count
        Sent       = $false
    }

    if (-not $pending) {
        return $run
    }
    if (-not $settings.Enabled) {
        Write-Verbose "Alerts are disabled: $($pending.Count) not sent. Enable with Set-FathomAlertSetting -Enabled `$true."
        return $run
    }

    $titles = [ordered] @{ new = 'NEW'; reminder = 'STILL ACTIVE'; resolved = 'RESOLVED' }
    $sections = foreach ($kind in $titles.Keys) {
        $rows = @($pending | Where-Object kind -EQ $kind)
        if ($rows) {
            $titles[$kind]
            foreach ($row in $rows) {
                $when = if ($kind -eq 'resolved') {
                    "active $($row.began.ToString('yyyy-MM-dd HH:mm')) to $($row.resolved_at.ToString('yyyy-MM-dd HH:mm'))"
                } else {
                    "since $($row.began.ToString('yyyy-MM-dd HH:mm'))"
                }
                "  [$($row.severity)] $($row.message) ($when)"
            }
            ''
        }
    }
    $counts = @(
        if ($run.New) { "$($run.New) new" }
        if ($run.Reminders) { "$($run.Reminders) still active" }
        if ($run.Resolved) { "$($run.Resolved) resolved" }
    ) -join ', '
    $critical = $pending | Where-Object { $_.kind -ne 'resolved' -and $_.severity -eq 'Critical' }
    $subject = "$(if ($critical) { '[Critical] ' })Fathom alerts: $counts"
    $body = (@("Fathom license monitoring: $counts.", '') + $sections) -join [Environment]::NewLine

    if (-not $PSCmdlet.ShouldProcess(($settings.To -join ', '), "Send alert digest ($counts)")) {
        return $run
    }
    Send-FathomMail @mail -Subject $subject -Body $body

    # Marked only after a successful send, so a failed one is retried next run.
    $sent = @'
UPDATE alert_state SET last_notified_at = @now::timestamp WHERE resolved_at IS NULL AND alert_key = ANY(@keys);
UPDATE alert_state SET resolution_notified = TRUE WHERE resolved_at IS NOT NULL AND alert_key = ANY(@keys);
'@
    $null = Invoke-FathomSql -Query $sent -Parameters @{ now = $now; keys = [string[]] @($pending.alert_key) }
    $run.Sent = $true
    $run
}
