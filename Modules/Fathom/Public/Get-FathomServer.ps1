function Get-FathomServer {
    <#
    .SYNOPSIS
        Lists the license servers Fathom monitors.
    .EXAMPLE
        Get-FathomServer -Enabled | Sync-FathomDebugLog
    #>
    [CmdletBinding()]
    [OutputType('Fathom.Server')]
    param(
        # One server. Without it, all are returned.
        [Parameter(ValueFromPipelineByPropertyName)]
        [string] $ServerId,

        # Only servers that are switched on for monitoring.
        [switch] $Enabled,

        # Only servers whose poll interval has passed.
        [switch] $Due
    )

    process {
        $query = @'
SELECT server_id, name, license_spec, log_path, vendor, enabled, usage_source, created_at,
       poll_timeout_seconds, poll_minutes,
       last_polled_at, last_poll_status, last_poll_message,
       last_log_read_at, last_log_line_at, last_log_status, last_log_error
FROM monitored_servers
WHERE (@server_id::text IS NULL OR server_id = @server_id)
  AND (NOT @enabled_only OR enabled)
  -- A minute's grace: schedules start a little late, and a run shouldn't just miss being due.
  AND (NOT @due_only OR last_polled_at IS NULL
       OR last_polled_at <= @now::timestamp - make_interval(mins => poll_minutes - 1))
ORDER BY server_id
'@
        $parameters = @{
            server_id    = if ($ServerId) { $ServerId } else { [DBNull]::Value }
            enabled_only = $Enabled.IsPresent
            due_only     = $Due.IsPresent
            now          = Get-Date | ConvertTo-FathomSqlTime
        }

        foreach ($row in Invoke-FathomQuery -Query $query -Parameters $parameters) {
            [pscustomobject] @{
                PSTypeName         = 'Fathom.Server'
                ServerId           = $row.server_id
                Name               = $row.name
                LicenseSpec        = $row.license_spec
                LogPath            = $row.log_path
                Vendor             = $row.vendor
                Enabled            = $row.enabled
                UsageSource        = $row.usage_source
                PollTimeoutSeconds = $row.poll_timeout_seconds
                PollMinutes        = $row.poll_minutes
                CreatedAt          = $row.created_at
                LastPolled         = $row.last_polled_at
                PollStatus         = $row.last_poll_status
                PollMessage        = $row.last_poll_message
                LastLogRead        = $row.last_log_read_at
                LastLogLine        = $row.last_log_line_at
                LogStatus          = $row.last_log_status
                LogError           = $row.last_log_error
            }
        }
    }
}
