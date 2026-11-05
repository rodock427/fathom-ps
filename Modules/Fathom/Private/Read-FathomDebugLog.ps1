function Read-FathomDebugLog {
    <#
    .SYNOPSIS
        Reads what is new in one server's debug log into license events; every outcome is returned as a result.
    #>
    [CmdletBinding()]
    [OutputType('Fathom.SyncResult')]
    param(
        [Parameter(Mandatory)] [string] $ServerId,
        [Parameter(Mandatory)] [string] $LogPath,
        [Parameter(Mandatory)] [int] $ChunkSize,
        [Nullable[datetime]] $StartDate
    )

    $result = [pscustomobject] @{
        PSTypeName    = 'Fathom.SyncResult'
        ServerId      = $ServerId
        LogPath       = $LogPath
        Status        = 'UpToDate'
        LinesRead     = 0
        EventsWritten = 0
        Offset        = 0
        Message       = $null
    }

    # Checking first keeps a missing share to one clean error for the caller
    # (a caught exception would also land in the caller's -ErrorVariable).
    if (-not [System.IO.File]::Exists($LogPath)) {
        $result.Status = 'Unreachable'
        $result.Message = "can't find or reach ${LogPath}."
        return $result
    }
    try {
        # Share everything: lmgrd keeps writing, and log rotation may rename or delete the file.
        $stream = [System.IO.File]::Open($LogPath, 'Open', 'Read', 'ReadWrite, Delete')
    } catch {
        $result.Status = 'Unreachable'
        $result.Message = "can't open ${LogPath}: $($_.Exception.Message)"
        return $result
    }

    try {
        $fingerprint = Get-FathomLogFingerprint -Stream $stream
        if (-not $fingerprint) {
            $result.Status = 'WaitingForFirstLine'
            return $result
        }

        $fileKey = "psu:${ServerId}:$fingerprint"
        $position = Get-FathomReadPosition -FileKey $fileKey
        $result.Offset = $position.Offset

        if ($position.Offset -gt $stream.Length) {
            # Same first line but shorter than before: not a rotation we can tell apart.
            # Re-reading would reuse old event ids and silently drop the new lines, so stop and say so.
            $result.Status = 'Shrunk'
            $result.Message = "${LogPath} shrank below the saved position but starts the same. Skipped; check how this log is rotated."
            return $result
        }

        $contextArgs = @{
            ServerId    = $ServerId
            SourceFile  = $LogPath
            SourceHash  = $fileKey
            CurrentDate = $position.CurrentDate ?? $StartDate
            LastTime    = $position.LastTime
            LineNumber  = $position.LineNumber
        }
        $context = New-FathomParserContext @contextArgs
        $eventsWritten = $position.EventsWritten
        $buffer = [byte[]]::new($ChunkSize)
        $stream.Position = $position.Offset

        while ($true) {
            $read = $stream.ReadAtLeast($buffer, $buffer.Length, $false)
            $end = if ($read) { [Array]::LastIndexOf($buffer, [byte] 10, $read - 1) } else { -1 }
            if ($end -lt 0) {
                if ($read -eq $buffer.Length) {
                    $result.Status = 'LineTooLong'
                    $result.Message = "a line in ${LogPath} is longer than -ChunkSize ($ChunkSize bytes)."
                }
                break  # nothing new, or only a line still being written
            }

            $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $end + 1)
            $lines = $text -split '\r\n|\n|\r'
            # The chunk ends with a newline, so the split always leaves one empty tail.
            $lines = $lines[0..($lines.Count - 2)]
            $events = @($lines | ConvertFrom-FathomDebugLog -Context $context)

            Start-FathomTransaction
            try {
                $written = Write-FathomLicenseEvent -InputObject $events
                $eventsWritten += $written
                $offset = $result.Offset + $end + 1
                Save-FathomReadPosition -FileKey $fileKey -Path $LogPath -Offset $offset -EventsWritten $eventsWritten -Context $context
                Save-FathomLogCoverage -FileKey $fileKey -ServerId $ServerId -InputObject $events
                Complete-FathomTransaction
            } catch {
                Undo-FathomTransaction
                throw
            }

            $result.Status = 'Synced'
            $result.LinesRead += $lines.Count
            $result.EventsWritten += $written
            $result.Offset = $offset
            $stream.Position = $offset

            if ($read -lt $buffer.Length) {
                break  # reached the end of what lmgrd has written so far
            }
        }

        $result
    } finally {
        $stream.Dispose()
    }
}
