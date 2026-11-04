function Sync-FathomLiveStatus {
    <#
    .SYNOPSIS
        Polls each server with `lmutil lmstat -a` and records live usage, seat limits and up/down.
    .DESCRIPTION
        Per feature, refreshes live_status (in use right now) and the seat count in
        feature_inventory, never touching admin-entered cost or token family. The poll's
        outcome (Up, Down or Timeout) is kept on the server record, so lmstat-only servers
        still show whether they're reachable.
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

        $status, $message = if ($run.TimedOut) {
            'Timeout', "lmutil gave no answer within $TimeoutSeconds seconds."
        } elseif ($run.Output -match 'license server UP') {
            'Up', $null
        } else {
            # lmutil's own error line says why (connection refused, bad port, ...).
            $reason = ($run.Output -split '\r?\n' | Where-Object { $_ -match 'error|cannot' } | Select-Object -First 1)
            'Down', ($reason ?? "lmutil exited with code $($run.ExitCode).").Trim()
        }

        Start-SqlTransaction -ConnectionName $script:ConnectionName
        try {
            foreach ($feature in $statuses) {
                Save-FathomFeatureStatus -Status $feature
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
            Message    = $message
            PolledAt   = $polledAt
        }
    }
}
