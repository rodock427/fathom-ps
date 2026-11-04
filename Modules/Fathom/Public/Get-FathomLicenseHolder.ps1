function Get-FathomLicenseHolder {
    <#
    .SYNOPSIS
        Who holds a seat right now, since when, per the latest lmstat poll. Individual data: Operator tier.
    .EXAMPLE
        Get-FathomLicenseHolder | Where-Object Long
    #>
    [CmdletBinding()]
    [OutputType('Fathom.LicenseHolder')]
    param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [string] $ServerId,

        [string] $Feature,

        # Sessions held longer than this are flagged as Long: often a forgotten open application.
        [ValidateRange(1, 8760)]
        [int] $LongAfterHours = 24
    )

    process {
        $query = @'
SELECT ls.server_id, ls.feature, ls."user", ls.host, ls.display, ls.licenses, ls.started_at, ls.captured_at
FROM live_sessions ls
JOIN monitored_servers s ON s.server_id = ls.server_id AND ls.captured_at = s.last_polled_at
WHERE s.enabled
  AND (@server_id::text IS NULL OR ls.server_id = @server_id)
  AND (@feature::text IS NULL OR ls.feature = @feature)
ORDER BY ls.started_at
'@
        $parameters = @{
            server_id = if ($ServerId) { $ServerId } else { [DBNull]::Value }
            feature   = if ($Feature) { $Feature } else { [DBNull]::Value }
        }

        foreach ($row in Invoke-FathomQuery -Query $query -Parameters $parameters) {
            $hours = if ($row.started_at) { [Math]::Round(($row.captured_at - $row.started_at).TotalHours, 1) } else { $null }
            [pscustomobject] @{
                PSTypeName = 'Fathom.LicenseHolder'
                ServerId   = $row.server_id
                Feature    = $row.feature
                User       = $row.user
                Host       = $row.host
                Licenses   = $row.licenses
                StartedAt  = $row.started_at
                Hours      = $hours
                Long       = [bool] ($hours -ge $LongAfterHours)
                AsOf       = $row.captured_at
            }
        }
    }
}
