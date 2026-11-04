function Get-FathomAvailability {
    <#
    .SYNOPSIS
        Free seats per feature right now, from each server's latest lmstat poll.
    .DESCRIPTION
        Only features in the latest poll count, so ones that stopped being reported don't
        linger. A server whose latest poll failed shows nothing (see Get-FathomServerHealth),
        and a feature whose vendor daemon is down shows no free seats.
    .EXAMPLE
        Get-FathomAvailability | Where-Object Free -EQ 0
    #>
    [CmdletBinding()]
    [OutputType('Fathom.Availability')]
    param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [string] $ServerId
    )

    process {
        $query = @'
SELECT s.server_id, s.name, l.feature, l.vendor_daemon, l.licenses_issued, l.licenses_in_use,
       COALESCE(d.up, TRUE) AS daemon_up, fi.expiration, l.captured_at
FROM monitored_servers s
JOIN live_status l ON l.server_id = s.server_id AND l.captured_at = s.last_polled_at
LEFT JOIN vendor_daemon_status d ON d.server_id = s.server_id AND d.daemon = l.vendor_daemon
LEFT JOIN feature_inventory fi ON fi.server_id = s.server_id AND fi.feature = l.feature
WHERE s.enabled AND s.last_poll_status IN ('Up', 'Degraded')
  AND (@server_id::text IS NULL OR s.server_id = @server_id)
ORDER BY s.server_id, l.feature
'@
        $parameters = @{ server_id = if ($ServerId) { $ServerId } else { [DBNull]::Value } }

        foreach ($row in Invoke-FathomQuery -Query $query -Parameters $parameters) {
            # In use can exceed issued (borrowed or overdraft seats), so free never goes negative.
            $free = if ($row.daemon_up) { [Math]::Max(0, $row.licenses_issued - $row.licenses_in_use) } else { 0 }
            [pscustomobject] @{
                PSTypeName  = 'Fathom.Availability'
                ServerId    = $row.server_id
                Server      = $row.name
                Feature     = $row.feature
                Vendor      = $row.vendor_daemon
                Issued      = $row.licenses_issued
                InUse       = $row.licenses_in_use
                Free        = $free
                PercentUsed = if ($row.licenses_issued) { [Math]::Round(100 * $row.licenses_in_use / $row.licenses_issued) } else { $null }
                DaemonUp    = $row.daemon_up
                Expires     = $row.expiration
                AsOf        = $row.captured_at
            }
        }
    }
}
