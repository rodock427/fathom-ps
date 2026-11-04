function Get-FathomExpiry {
    <#
    .SYNOPSIS
        Features on monitored servers that expire within the given number of days.
    .EXAMPLE
        Get-FathomExpiry -WithinDays 30
    #>
    [CmdletBinding()]
    [OutputType('Fathom.Expiry')]
    param(
        [ValidateRange(0, 3650)]
        [int] $WithinDays = 90,

        # Also list features that have already expired.
        [switch] $IncludeExpired
    )

    $query = @'
SELECT fi.server_id, s.name, fi.feature, fi.vendor_daemon, fi.licenses_issued, fi.expiration
FROM feature_inventory fi
JOIN monitored_servers s ON s.server_id = fi.server_id AND s.enabled
WHERE fi.expiration IS NOT NULL
  AND fi.expiration <= @until::date
  AND (@include_expired OR fi.expiration >= @today::date)
ORDER BY fi.expiration, fi.server_id, fi.feature
'@
    $today = (Get-Date).Date
    $parameters = @{
        today           = $today.ToString('yyyy-MM-dd')
        until           = $today.AddDays($WithinDays).ToString('yyyy-MM-dd')
        include_expired = $IncludeExpired.IsPresent
    }

    foreach ($row in Invoke-FathomQuery -Query $query -Parameters $parameters) {
        [pscustomobject] @{
            PSTypeName = 'Fathom.Expiry'
            ServerId   = $row.server_id
            Server     = $row.name
            Feature    = $row.feature
            Vendor     = $row.vendor_daemon
            Seats      = $row.licenses_issued
            Expires    = $row.expiration
            DaysLeft   = [int] ($row.expiration - $today).TotalDays
        }
    }
}
