function Get-FathomReadPosition {
    <#
    .SYNOPSIS
        Where the last read of a log stopped, or a fresh start if it has never been read.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $FileKey
    )

    $query = @'
SELECT resume_offset, line_number, resolved_date, total_events_written
FROM _ingest_manifest WHERE file_key = @file_key
'@
    $saved = Invoke-FathomQuery -Query $query -Parameters @{ file_key = $FileKey }

    # resolved_date holds the running date plus the last line's time of day (midnight = none).
    $resolved = $saved.resolved_date
    [pscustomobject] @{
        Offset        = [long] $saved.resume_offset
        LineNumber    = [long] $saved.line_number
        CurrentDate   = if ($resolved) { $resolved.Date } else { $null }
        LastTime      = if ($resolved -and $resolved.TimeOfDay -ne [timespan]::Zero) { $resolved.TimeOfDay } else { $null }
        EventsWritten = [long] $saved.total_events_written
    }
}
