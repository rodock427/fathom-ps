function Write-FathomLicenseEvent {
    <#
    .SYNOPSIS
        Inserts license events, skipping ids already stored. Returns how many rows were new.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [PSTypeName('Fathom.LicenseEvent')] [object[]] $InputObject,

        # Rows per statement. Each batch travels as one JSON parameter.
        [ValidateRange(1, 10000)]
        [int] $BatchSize = 1000
    )

    $query = @'
INSERT INTO license_events (
    event_id, event_type, timestamp, server_format, server_id, feature, vendor_daemon,
    "user", host, display, version, licenses_in_use, licenses_available, queue_position,
    handle, unit_count, raw_line, source_file, line_number, ingest_batch_id)
SELECT * FROM jsonb_to_recordset(@rows::jsonb) AS r(
    event_id text, event_type text, timestamp timestamp, server_format text, server_id text,
    feature text, vendor_daemon text, "user" text, host text, display text, version text,
    licenses_in_use int, licenses_available int, queue_position int, handle text,
    unit_count int, raw_line text, source_file text, line_number int, ingest_batch_id text)
ON CONFLICT (event_id) DO NOTHING
'@

    $written = 0
    for ($start = 0; $start -lt $InputObject.Count; $start += $BatchSize) {
        $batch = $InputObject[$start..([Math]::Min($start + $BatchSize, $InputObject.Count) - 1)]
        $rows = foreach ($item in $batch) {
            [ordered] @{
                event_id           = $item.EventId
                event_type         = $item.EventType
                # Explicit format: the column has no time zone, so none may be sent.
                timestamp          = $item.Timestamp.ToString('yyyy-MM-dd HH:mm:ss.fffffff')
                server_format      = $item.ServerFormat
                server_id          = $item.ServerId
                feature            = $item.Feature
                vendor_daemon      = $item.VendorDaemon
                user               = $item.User
                host               = $item.Host
                display            = $item.Display
                version            = $item.Version
                licenses_in_use    = $item.LicensesInUse
                licenses_available = $item.LicensesAvailable
                queue_position     = $item.QueuePosition
                handle             = $item.Handle
                unit_count         = $item.UnitCount
                raw_line           = $item.RawLine
                source_file        = $item.SourceFile
                line_number        = $item.LineNumber
                ingest_batch_id    = $item.IngestBatchId
            }
        }
        $json = ConvertTo-Json -InputObject @($rows) -Compress -Depth 2
        $written += Invoke-FathomSql -Query $query -Parameters @{ rows = $json }
    }

    $written
}
