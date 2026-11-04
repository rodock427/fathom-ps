function Save-FathomReadPosition {
    <#
    .SYNOPSIS
        Records how far a log has been read, in Fathom's _ingest_manifest table.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $FileKey,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [long] $Offset,
        [Parameter(Mandatory)] [long] $EventsWritten,
        [Parameter(Mandatory)] [PSTypeName('Fathom.ParserContext')] $Context
    )

    # Times are the PowerShell host's local clock, like event timestamps and Fathom's own
    # writes. The database's now() could be in another time zone.
    $query = @'
INSERT INTO _ingest_manifest (
    file_key, last_known_path, server_id, resume_offset, line_number,
    resolved_date, last_batch_id, last_ingested_at, total_events_written)
VALUES (@file_key, @path, @server_id, @offset, @line_number, @resolved_date::timestamp, @batch_id, @ingested_at::timestamp, @events)
ON CONFLICT (file_key) DO UPDATE SET
    last_known_path = EXCLUDED.last_known_path,
    resume_offset = EXCLUDED.resume_offset,
    line_number = EXCLUDED.line_number,
    resolved_date = EXCLUDED.resolved_date,
    last_batch_id = EXCLUDED.last_batch_id,
    last_ingested_at = EXCLUDED.last_ingested_at,
    total_events_written = EXCLUDED.total_events_written
'@
    $parameters = @{
        file_key      = $FileKey
        path          = $Path
        server_id     = $Context.ServerId
        offset        = $Offset
        line_number   = $Context.LineNumber
        resolved_date = if ($Context.CurrentDate) { $Context.CurrentDate.ToString('yyyy-MM-dd HH:mm:ss') } else { [DBNull]::Value }
        batch_id      = $Context.BatchId
        events        = $EventsWritten
        ingested_at   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $null = Invoke-SqlUpdate -ConnectionName $script:ConnectionName -Query $query -Parameters $parameters
}
