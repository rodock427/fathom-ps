function Get-FathomActivity {
    <#
    .SYNOPSIS
        The most recent debug-log events for a server, newest first. Individual data: Operator tier.
    .EXAMPLE
        Get-FathomActivity -ServerId licsrv01 -Last 50
    #>
    [CmdletBinding()]
    [OutputType('Fathom.Activity')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string] $ServerId,

        [ValidateRange(1, 10000)]
        [int] $Last = 100,

        # e.g. checkout, denied, server_up, unsupported. All when omitted.
        [string[]] $EventType
    )

    process {
        $query = @'
SELECT timestamp, event_type, feature, "user", host, unit_count, raw_line
FROM license_events
WHERE server_id = @server_id AND (@all_types OR event_type = ANY(@types))
ORDER BY timestamp DESC, line_number DESC
LIMIT @last
'@
        $parameters = @{
            server_id = $ServerId
            all_types = -not $EventType
            types     = [string[]] @($EventType)
            last      = $Last
        }

        foreach ($row in Invoke-FathomQuery -Query $query -Parameters $parameters) {
            [pscustomobject] @{
                PSTypeName = 'Fathom.Activity'
                Time       = $row.timestamp
                Event      = $row.event_type
                Feature    = $row.feature
                User       = $row.user
                Host       = $row.host
                Licenses   = $row.unit_count
                Line       = $row.raw_line
            }
        }
    }
}
