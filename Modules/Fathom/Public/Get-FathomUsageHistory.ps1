function Get-FathomUsageHistory {
    <#
    .SYNOPSIS
        Peak seats in use against seats issued, per time bucket, for one server's features.
    .DESCRIPTION
        Comes from the server's effective usage source (see Get-FathomServerHealth) unless
        -Source overrides it; each point says which source it came from. From the debug log
        the peak is exact, including seats held from before -From; from lmstat it's the
        highest 5-minute reading. Buckets with no data are left out rather than shown as zero.
    .EXAMPLE
        Get-FathomUsageHistory -ServerId licsrv01 -Feature MATLAB -From (Get-Date).AddDays(-7)
    #>
    [CmdletBinding()]
    [OutputType('Fathom.UsagePoint')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string] $ServerId,

        # Features to include. All when omitted.
        [string[]] $Feature,

        [datetime] $From = (Get-Date).AddDays(-1),

        [datetime] $To = (Get-Date),

        # Bucket size. Defaults to suit the range: 5 minutes up to 2 days, hourly up to 14, then daily.
        # Up to a year, so one bucket can span a whole period (each feature's peak).
        [ValidateRange(1, 527040)]
        [int] $IntervalMinutes,

        [ValidateSet('Auto', 'Log', 'Lmstat')]
        [string] $Source = 'Auto'
    )

    process {
        if ($To -le $From) {
            throw '-To must be later than -From.'
        }
        if (-not $IntervalMinutes) {
            $days = ($To - $From).TotalDays
            $IntervalMinutes = if ($days -le 2) { 5 } elseif ($days -le 14) { 60 } else { 1440 }
        }

        # Auto means "the server's own setting"; health turns that into log, lmstat or per-bucket auto.
        $resolved = if ($Source -ne 'Auto') {
            $Source.ToLowerInvariant()
        } else {
            (Get-FathomServerHealth -ServerId $ServerId).EffectiveSource
        }
        if (-not $resolved) {
            throw "Server '$ServerId' isn't registered."
        }

        $query = (Get-FathomSeriesSql -Source $resolved) + @'
SELECT feature, bucket, peak_in_use, issued, source FROM series ORDER BY feature, bucket
'@
        $parameters = @{
            server_id    = $ServerId
            from         = $From | ConvertTo-FathomSqlTime
            to           = $To | ConvertTo-FathomSqlTime
            step_minutes = $IntervalMinutes
            all_features = -not $Feature
            features     = [string[]] @($Feature)
        }

        foreach ($row in Invoke-FathomQuery -Query $query -Parameters $parameters) {
            [pscustomobject] @{
                PSTypeName  = 'Fathom.UsagePoint'
                ServerId    = $ServerId
                Feature     = $row.feature
                BucketStart = $row.bucket
                PeakInUse   = [int] $row.peak_in_use
                Issued      = $row.issued
                Source      = $row.source
            }
        }
    }
}
