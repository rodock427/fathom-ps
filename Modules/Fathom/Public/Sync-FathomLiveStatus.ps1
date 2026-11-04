function Sync-FathomLiveStatus {
    <#
    .SYNOPSIS
        Polls each server with `lmutil lmstat -a`: live usage, history, holders, seats, expiry, health.
    .DESCRIPTION
        Per feature: refreshes live_status (in use now), adds a usage_samples row (so even
        lmstat-only servers have a history), replaces the current holders in live_sessions,
        and updates seats and expiry in feature_inventory without touching admin-entered cost.
        Each vendor daemon's state goes to vendor_daemon_status. The outcome (Up, Degraded when
        a vendor daemon is down, Down or Timeout) is kept on the server record.
    .EXAMPLE
        Get-FathomServer -Enabled | Sync-FathomLiveStatus -LmutilPath 'C:\FlexLM\lmutil.exe'
    #>
    [CmdletBinding()]
    [OutputType('Fathom.PollResult')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string] $ServerId,

        # What lmutil -c is given. Servers monitored by log only have none; they're skipped.
        [Parameter(ValueFromPipelineByPropertyName)]
        [AllowEmptyString()]
        [string] $LicenseSpec,

        # lmutil executable. Defaults to $env:FATHOM_LMUTIL, then lmutil on PATH.
        [string] $LmutilPath = ($env:FATHOM_LMUTIL ?? 'lmutil'),

        [ValidateRange(1, 600)]
        [int] $TimeoutSeconds = 60
    )

    begin {
        # A missing lmutil is a setup problem, not a server problem: fail once, up front.
        $lmutil = (Get-Command -Name $LmutilPath -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    }

    process {
        if (-not $LicenseSpec) {
            Write-Verbose "${ServerId}: no license spec, skipping."
            return
        }

        $polledAt = Get-Date
        $run = Invoke-FathomLmutil -Path $lmutil -ArgumentList 'lmstat', '-a', '-c', $LicenseSpec -TimeoutSeconds $TimeoutSeconds
        $statuses = @($run.Output | ConvertFrom-FathomLmstat -ServerId $ServerId -CapturedAt $polledAt)

        $health = Get-FathomLmstatHealth -Output $run.Output
        $downDaemons = @($health.Daemons | Where-Object { -not $_.Up })

        $status, $message = if ($run.TimedOut) {
            'Timeout', "lmutil gave no answer within $TimeoutSeconds seconds."
        } elseif ($health.ServerUp -and $downDaemons) {
            # lmgrd answers but nobody can check out from these daemons' features.
            'Degraded', (($downDaemons | ForEach-Object { "$($_.Name): $($_.Detail)" }) -join '; ')
        } elseif ($health.ServerUp) {
            'Up', $null
        } else {
            # lmutil's own error line says why (connection refused, bad port, ...).
            $reason = ($run.Output -split '\r?\n' | Where-Object { $_ -match 'error|cannot' } | Select-Object -First 1)
            'Down', ($reason ?? "lmutil exited with code $($run.ExitCode).").Trim()
        }

        Start-SqlTransaction -ConnectionName $script:ConnectionName
        try {
            # Holders and daemon states are "as of this poll": a server that's down holds nothing.
            $clear = 'DELETE FROM live_sessions WHERE server_id = @server_id; DELETE FROM vendor_daemon_status WHERE server_id = @server_id;'
            $null = Invoke-SqlUpdate -ConnectionName $script:ConnectionName -Query $clear -Parameters @{ server_id = $ServerId }

            foreach ($feature in $statuses) {
                Save-FathomFeatureStatus -Status $feature
            }

            $daemonQuery = @'
INSERT INTO vendor_daemon_status (server_id, daemon, up, detail, captured_at)
VALUES (@server_id, @daemon, @up, @detail, @captured_at::timestamp)
ON CONFLICT (server_id, daemon) DO UPDATE SET up = EXCLUDED.up, detail = EXCLUDED.detail, captured_at = EXCLUDED.captured_at
'@
            foreach ($daemon in $health.Daemons) {
                $daemonParameters = @{
                    server_id   = $ServerId
                    daemon      = $daemon.Name
                    up          = $daemon.Up
                    detail      = $daemon.Detail
                    captured_at = $polledAt.ToString('yyyy-MM-dd HH:mm:ss')
                }
                $null = Invoke-SqlUpdate -ConnectionName $script:ConnectionName -Query $daemonQuery -Parameters $daemonParameters
            }

            $query = @'
UPDATE monitored_servers
SET last_polled_at = @polled_at::timestamp, last_poll_status = @status, last_poll_message = @message
WHERE server_id = @server_id
'@
            $parameters = @{
                server_id = $ServerId
                polled_at = $polledAt.ToString('yyyy-MM-dd HH:mm:ss')
                status    = $status
                message   = $message ?? [DBNull]::Value
            }
            $null = Invoke-SqlUpdate -ConnectionName $script:ConnectionName -Query $query -Parameters $parameters
            Complete-SqlTransaction -ConnectionName $script:ConnectionName
        } catch {
            Undo-SqlTransaction -ConnectionName $script:ConnectionName
            throw
        }

        [pscustomobject] @{
            PSTypeName = 'Fathom.PollResult'
            ServerId   = $ServerId
            Status     = $status
            Features   = $statuses.Count
            Holders    = ($statuses.Holders | Measure-Object).Count
            Message    = $message
            PolledAt   = $polledAt
        }
    }
}
