function Get-FathomDenial {
    <#
    .SYNOPSIS
        Checkout requests the license server turned away, from the debug logs. Individual data: Operator tier.
    .EXAMPLE
        Get-FathomDenial -From (Get-Date).AddDays(-1) -Feature MATLAB
    #>
    [CmdletBinding()]
    [OutputType('Fathom.Denial')]
    param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [string] $ServerId,

        [string] $Feature,

        [string] $User,

        [datetime] $From = (Get-Date).AddDays(-1),

        [datetime] $To = (Get-Date)
    )

    process {
        $query = @'
SELECT timestamp, server_id, feature, "user", host, unit_count
FROM license_events
WHERE event_type = 'denied' AND timestamp >= @from::timestamp AND timestamp < @to::timestamp
  AND (@server_id::text IS NULL OR server_id = @server_id)
  AND (@feature::text IS NULL OR feature = @feature)
  AND (@user::text IS NULL OR "user" = @user)
ORDER BY timestamp DESC
'@
        $parameters = @{
            server_id = if ($ServerId) { $ServerId } else { [DBNull]::Value }
            feature   = if ($Feature) { $Feature } else { [DBNull]::Value }
            user      = if ($User) { $User } else { [DBNull]::Value }
            from      = $From | ConvertTo-FathomSqlTime
            to        = $To | ConvertTo-FathomSqlTime
        }

        foreach ($row in Invoke-FathomQuery -Query $query -Parameters $parameters) {
            [pscustomobject] @{
                PSTypeName = 'Fathom.Denial'
                Time       = $row.timestamp
                ServerId   = $row.server_id
                Feature    = $row.feature
                User       = $row.user
                Host       = $row.host
                Licenses   = $row.unit_count
            }
        }
    }
}
