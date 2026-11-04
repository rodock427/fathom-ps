function Sync-FathomDebugLog {
    <#
    .SYNOPSIS
        Reads what is new in each server's lmgrd debug log and stores it as license events.
    .DESCRIPTION
        Picks up where the previous read stopped and only consumes complete lines, so a line
        lmgrd is still writing is left for next time. Each chunk's events and the new read
        position are committed together, so a crash never skips or double-counts lines.
        A replaced or truncated log is detected by its first line and read from the start.
        Every attempt records the log's health on the server, so a share that quietly
        stopped working shows up.
    .EXAMPLE
        Get-FathomServer -Enabled | Sync-FathomDebugLog
    #>
    [CmdletBinding()]
    [OutputType('Fathom.SyncResult')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string] $ServerId,

        # Servers monitored by lmstat only have no log path; they're skipped.
        [Parameter(ValueFromPipelineByPropertyName)]
        [AllowEmptyString()]
        [string] $LogPath,

        # Bytes read per transaction. Bounds memory on a large first read.
        [ValidateRange(4KB, 256MB)]
        [int] $ChunkSize = 4MB
    )

    process {
        if (-not $LogPath) {
            Write-Verbose "${ServerId}: no log path, skipping."
            return
        }

        $result = Read-FathomDebugLog -ServerId $ServerId -LogPath $LogPath -ChunkSize $ChunkSize

        $query = @'
UPDATE monitored_servers SET
    last_log_read_at = @read_at::timestamp,
    last_log_line_at = CASE WHEN @new_lines THEN @read_at::timestamp ELSE last_log_line_at END,
    last_log_status = @status,
    last_log_error = @error
WHERE server_id = @server_id
'@
        $parameters = @{
            server_id = $ServerId
            read_at   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            new_lines = $result.LinesRead -gt 0
            status    = $result.Status
            error     = $result.Message ?? [DBNull]::Value
        }
        $null = Invoke-SqlUpdate -ConnectionName $script:ConnectionName -Query $query -Parameters $parameters

        # Problems are non-terminating: one unreachable share mustn't stop the other servers.
        switch ($result.Status) {
            'Unreachable' { Write-Error -Message "${ServerId}: $($result.Message)" -TargetObject $ServerId -Category ObjectNotFound }
            'LineTooLong' { Write-Error -Message "${ServerId}: $($result.Message)" -TargetObject $ServerId }
            'Shrunk' { Write-Warning "${ServerId}: $($result.Message)" }
        }

        # An unreachable log has nothing to report beyond the error.
        if ($result.Status -ne 'Unreachable') {
            $result
        }
    }
}
