# One server. Everyone: usage against seats per feature, health and uptime. Operators also see
# who holds seats, denials and the debug log's recent activity.
. "$PSScriptRoot/../Common.ps1"

if (-not (Test-FathomAccess -Tier Reader -Role $Roles)) {
    return New-FathomNotAuthorized
}

$operator = Test-FathomAccess -Tier Operator -Role $Roles
# Days shown, and the chart's bucket size for each: about 100 points whatever the range.
$bucketMinutes = @{ 1 = 15; 7 = 60; 30 = 240; 90 = 720; 365 = 1440 }
$rangeDays = 1, 7, 30, 90, 365
$days = Get-FathomQueryRange -Value $Query.days -Days $rangeDays -Default 7
$from = (Get-Date).AddDays(-$days)

Use-FathomDatabase {
    $servers = @(Get-FathomServer | Sort-Object Name)
    $server = $servers | Where-Object ServerId -EQ $Query.id | Select-Object -First 1
    $server ??= $servers | Select-Object -First 1
    if (-not $server) {
        return New-UDAlert -Severity info -Text 'No servers are monitored yet.'
    }
    $id = $server.ServerId

    New-UDTypography -Variant h4 -Text $server.Name -GutterBottom
    New-UDStack -Direction column -Spacing 1 -Children {
        # A dropdown, not buttons: production may have dozens of servers.
        New-UDSelect -Id 'server-picker' -Label 'Server' -DefaultValue $id -Option {
            foreach ($other in $servers) {
                New-UDSelectOption -Name $other.Name -Value $other.ServerId
            }
        } -OnChange {
            Invoke-UDRedirect -Url "server?id=$([uri]::EscapeDataString($EventData))&days=$days"
        }
        New-FathomRangePicker -Days $rangeDays -Selected $days -Page 'server' -Query @{ id = $id; feature = $Query.feature }
    }

    $health = Get-FathomServerHealth -ServerId $id
    $uptime = Get-FathomServerUptime -ServerId $id -From $from
    New-UDCard -Title 'Health' -Content {
        New-UDStack -Direction row -Spacing 2 -AlignItems center -Children {
            New-UDChip -Label $health.Status -Color (Get-FathomStatusColor $health.Status)
            New-UDTypography -Text "Last lmstat poll $((Format-FathomTime $health.LastPolled) ?? 'never')"
            New-UDTypography -Text "Usage history from $($health.EffectiveSource)"
            if ($null -ne $uptime.UptimePercent) {
                New-UDTypography -Text "Up $($uptime.UptimePercent)% of polls, $($uptime.Outages) outage(s) in this period"
            }
        }
        if ($health.PollMessage -and $health.Status -ne 'Up') {
            New-UDTypography -Variant body2 -Text $health.PollMessage
        }
        if ($server.LogPath) {
            New-UDTypography -Variant body2 -Text "Debug log: $($health.LogStatus), last line $((Format-FathomTime $health.LastLogLine) ?? 'never')"
        }
    }

    # One bucket spanning the whole period gives each feature's peak cheaply, however many
    # features there are; full history is fetched only for the features charted.
    $inUseNow = @{}
    Get-FathomAvailability -ServerId $id | ForEach-Object { $inUseNow[$_.Feature] = $_.InUse }
    $features = foreach ($row in Get-FathomUsageHistory -ServerId $id -From $from -IntervalMinutes ($days * 1440)) {
        [pscustomobject] @{
            Feature     = $row.Feature
            Seats       = $row.Issued
            Peak        = $row.PeakInUse
            PeakPercent = if ($row.Issued) { [Math]::Round(100 * $row.PeakInUse / $row.Issued) } else { $null }
            InUseNow    = $inUseNow[$row.Feature]
            Link        = 'server?id={0}&days={1}&feature={2}' -f $id, $days, [uri]::EscapeDataString($row.Feature)
        }
    }

    # Busiest first: highest peak share of seats, then the most seats.
    $features = @($features | Sort-Object -Property @{ Expression = 'PeakPercent'; Descending = $true }, @{ Expression = 'Seats'; Descending = $true }, Feature)

    # A picked feature, else the busiest few. ponytail: 8 charts; a feature beyond that is one click away in the table.
    $chartLimit = 8
    $charted = if ($Query.feature) {
        @($features | Where-Object Feature -EQ $Query.feature)
    } else {
        @($features | Select-Object -First $chartLimit)
    }
    $title = if ($Query.feature) {
        $Query.feature
    } elseif ($features.Count -gt $chartLimit) {
        "Busiest $($charted.Count) of $($features.Count) features: pick any feature below to chart it"
    } else {
        'Usage against seats'
    }

    $labelFormat = if ($days -gt 7) { 'MM-dd' } else { 'MM-dd HH:mm' }
    $history = if ($charted) {
        Get-FathomUsageHistory -ServerId $id -From $from -IntervalMinutes $bucketMinutes[$days] -Feature $charted.Feature
    }
    New-UDTypography -Variant h6 -Text $title -GutterBottom
    if ($Query.feature) {
        New-UDLink -Text 'Back to the busiest features' -Url "server?id=$id&days=$days"
    }
    New-UDGrid -Container -Spacing 2 -Children {
        if (-not $history) {
            New-UDGrid -Item -ExtraSmallSize 12 -Children {
                New-UDTypography -Id 'server-usage' -Variant body2 -Text 'No usage recorded in this period.'
            }
        }
        foreach ($feature in $history | Group-Object Feature | Sort-Object Name) {
            $points = $feature.Group | Sort-Object BucketStart | ForEach-Object {
                [pscustomobject] @{ Time = $_.BucketStart.ToString($labelFormat); InUse = $_.PeakInUse; Seats = $_.Issued }
            }
            $width = if ($charted.Count -eq 1) { 12 } else { 6 }
            New-UDGrid -Item -ExtraSmallSize 12 -MediumSize $width -Children {
                New-UDCard -Title $feature.Name -Content {
                    $chart = @{
                        Id            = "server-usage-$($feature.Name)"
                        Type          = 'line'
                        Data          = $points
                        LabelProperty = 'Time'
                        Dataset       = @(
                            New-UDChartJSDataset -DataProperty InUse -Label 'In use (peak)' -BorderColor '#1976d2' -BackgroundColor '#1976d2' -BorderWidth 2
                            New-UDChartJSDataset -DataProperty Seats -Label 'Seats' -BorderColor '#9e9e9e' -BackgroundColor '#9e9e9e' -BorderWidth 2
                        )
                        Options       = @{
                            maintainAspectRatio = $false
                            elements            = @{ point = @{ radius = 0 }; line = @{ stepped = $true } }
                            scales              = @{
                                x = @{ ticks = @{ maxRotation = 0; autoSkip = $true; autoSkipPadding = 24; maxTicksLimit = 4 } }
                                y = @{ beginAtZero = $true; ticks = @{ precision = 0 } }
                            }
                        }
                    }
                    # Chart.js fills its container, so the container sets the height.
                    New-UDElement -Tag div -Attributes @{ style = @{ height = '240px' } } -Content { New-UDChartJS @chart }
                }
            }
        }
    }

    New-UDCard -Title "All features ($($features.Count))" -Content {
        $table = @{
            Id      = 'server-features'
            Data    = $features
            Columns = [ordered] @{ Feature = 'Feature'; Seats = 'Seats'; Peak = 'Peak in period'; PeakPercent = 'Peak %'; InUseNow = 'In use now' }
            Render  = @{ Feature = { New-UDLink -Text $EventData.Feature -Url $EventData.Link } }
            Empty   = 'No usage recorded in this period.'
        }
        New-FathomTable @table
    }

    if (-not $operator) {
        return
    }

    New-UDCard -Title 'Holding a seat now' -Content {
        $rows = Get-FathomLicenseHolder -ServerId $id | Sort-Object Feature, StartedAt | ForEach-Object {
            [pscustomobject] @{
                Feature  = $_.Feature
                User     = $_.User
                Host     = $_.Host
                Licenses = $_.Licenses
                Since    = Format-FathomTime $_.StartedAt
                Hours    = $_.Hours
                Long     = $_.Long
            }
        }
        $table = @{
            Id      = 'server-holders'
            Data    = $rows
            Columns = [ordered] @{ Feature = 'Feature'; User = 'User'; Host = 'Host'; Licenses = 'Seats'; Since = 'Since'; Hours = 'Hours' }
            Render  = @{
                User  = { New-UDLink -Text $EventData.User -Url "people?user=$([uri]::EscapeDataString($EventData.User))" }
                Hours = { New-UDChip -Label ([string] $EventData.Hours) -Color ($EventData.Long ? 'warning' : 'default') -Size small }
            }
            Empty   = 'Nobody holds a seat right now.'
        }
        New-FathomTable @table
    }

    New-UDCard -Title 'Denials in this period' -Content {
        $rows = Get-FathomDenial -ServerId $id -From $from | ForEach-Object {
            [pscustomobject] @{ Time = Format-FathomTime $_.Time; Feature = $_.Feature; User = $_.User; Host = $_.Host }
        }
        $table = @{
            Id      = 'server-denials'
            Data    = $rows
            Columns = [ordered] @{ Time = 'Time'; Feature = 'Feature'; User = 'User'; Host = 'Host' }
            Empty   = if ($server.LogPath) { 'No denials in this period.' } else { 'Denials come from the debug log, which this server has none of.' }
        }
        New-FathomTable @table
    }

    New-UDCard -Title 'Recent debug log activity' -Content {
        $rows = Get-FathomActivity -ServerId $id -Last 100 | ForEach-Object {
            [pscustomobject] @{ Time = Format-FathomTime $_.Time; Event = $_.Event; Feature = $_.Feature; User = $_.User; Host = $_.Host }
        }
        $table = @{
            Id      = 'server-activity'
            Data    = $rows
            Columns = [ordered] @{ Time = 'Time'; Event = 'Event'; Feature = 'Feature'; User = 'User'; Host = 'Host' }
            Empty   = 'No debug log events yet.'
        }
        New-FathomTable @table
    }
}
