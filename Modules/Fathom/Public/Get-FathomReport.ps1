function Get-FathomReport {
    <#
    .SYNOPSIS
        Runs a standard report: its rows, columns and any charts, ready to show or export.
    .DESCRIPTION
        -Option takes values as a page's query string carries them, so anything missing or out of
        range falls back to the report's default. The result's Options holds the values used.
        Some reports hold individual data: Operator tier.
    .EXAMPLE
        Get-FathomReport -Name denials -Option @{ group = 'user' } -From (Get-Date).AddDays(-7) -To (Get-Date)
    #>
    [CmdletBinding()]
    [OutputType('Fathom.Report')]
    param(
        # A name from Get-FathomReportCatalog.
        [Parameter(Mandatory)]
        [string] $Name,

        [hashtable] $Option = @{},

        [datetime] $From = (Get-Date).AddDays(-30),

        [datetime] $To = (Get-Date)
    )

    $definition = Get-FathomReportCatalog -Name $Name
    if (-not $definition) {
        throw "There is no report called '$Name'."
    }

    $values = @{}
    foreach ($spec in $definition.Options) {
        $raw = [string] $Option[$spec.Name]
        $number = 0
        $values[$spec.Name] = switch ($spec.Kind) {
            'Number' {
                $valid = [int]::TryParse($raw, [ref] $number) -and $number -ge $spec.Minimum -and $number -le $spec.Maximum
                if ($valid) { $number } else { $spec.Default }
            }
            'Choice' { if ($spec.Choices.Contains($raw)) { $raw } else { $spec.Default } }
            'Features' { , @($raw -split ',' | ForEach-Object Trim | Where-Object { $_ }) }
            default { $raw }
        }
    }

    $server = @{}
    if ($values.server) { $server.ServerId = $values.server }
    $period = @{ From = $From; To = $To }
    $feature = @{}
    if ($values.feature) { $feature.Feature = $values.feature }
    $charts = @()

    switch ($Name) {
        'seat-planning' {
            $capacity = @(Get-FathomCapacityReport @server @period -UnderusedBelow ($values.underused / 100) | Sort-Object ServerId, Feature)
            $rows = foreach ($row in $capacity) {
                [pscustomobject] @{
                    Server      = $row.ServerId
                    Feature     = $row.Feature
                    Seats       = $row.Seats
                    Peak        = $row.Peak
                    Typical     = $row.P95
                    AtCapacity  = $row.AtCapacityPercent
                    Denials     = $row.Denials
                    DeniedUsers = $row.DeniedUsers
                    ActiveUsers = $row.ActiveUsers
                    Flags       = @(if ($row.Underused) { 'underused' }; if ($row.Denials) { 'turning users away' }) -join ', '
                }
            }
            $columns = [ordered] @{
                Feature = 'Feature'; Seats = 'Seats'; Peak = 'Peak'; Typical = 'Typical'; AtCapacity = 'Time at capacity (%)'
                Denials = 'Denials'; DeniedUsers = 'Users denied'; ActiveUsers = 'Active users'; Flags = 'Flags'; Server = 'Server'
            }
            # ponytail: the 25 busiest on one chart; hundreds of bars can't be read anyway.
            $busiest = $rows | Sort-Object -Property @{ Expression = { $_.Seats ? $_.Peak / $_.Seats : 0 }; Descending = $true } | Select-Object -First 25
            if ($busiest) {
                $charts = @([pscustomobject] @{
                        Title  = 'The busiest features: peak and typical use against seats'
                        Type   = 'ColumnClustered'
                        Series = 'Peak', 'Typical', 'Seats'
                        Points = @($busiest | ForEach-Object {
                                [pscustomobject] @{ Label = "$($_.Feature) ($($_.Server))"; Peak = $_.Peak; Typical = $_.Typical; Seats = $_.Seats }
                            })
                    })
            }
        }

        'usage-history' {
            $step = @{}
            if ($values.step -ne 'auto') { $step.IntervalMinutes = [int] $values.step }
            $span = [Math]::Min(527040, [Math]::Max(1, [Math]::Ceiling(($To - $From).TotalMinutes)))
            $rows = foreach ($serverId in (Get-FathomServer @server).ServerId) {
                $picked = $values.features
                if (-not $picked) {
                    # One bucket spanning the period gives each feature's peak, whatever the step.
                    $peaks = Get-FathomUsageHistory -ServerId $serverId @period -IntervalMinutes $span
                    $picked = @($peaks | Sort-Object -Property @{ Expression = { $_.Issued ? $_.PeakInUse / $_.Issued : 0 }; Descending = $true }, Feature |
                            Select-Object -First $values.top -ExpandProperty Feature)
                }
                if ($picked) {
                    foreach ($point in Get-FathomUsageHistory -ServerId $serverId -Feature $picked @period @step | Sort-Object Feature, BucketStart) {
                        [pscustomobject] @{
                            Server  = $serverId
                            Feature = $point.Feature
                            Time    = $point.BucketStart
                            InUse   = $point.PeakInUse
                            Seats   = $point.Issued
                            Source  = $point.Source
                        }
                    }
                }
            }
            $columns = [ordered] @{ Server = 'Server'; Feature = 'Feature'; Time = 'Time'; InUse = 'In use (peak)'; Seats = 'Seats'; Source = 'Source' }
            $format = ($To - $From).TotalHours -le 48 ? 'MM-dd HH:mm' : 'yyyy-MM-dd HH:mm'
            $charts = @(foreach ($group in $rows | Group-Object Server, Feature) {
                    $first = $group.Group[0]
                    [pscustomobject] @{
                        Title  = "$($first.Feature) ($($first.Server))"
                        # A line needs two points; one reading (a server just added) is a bar.
                        Type   = $group.Count -gt 1 ? 'Line' : 'ColumnClustered'
                        Series = 'InUse', 'Seats'
                        Points = @($group.Group | ForEach-Object {
                                [pscustomobject] @{ Label = $_.Time.ToString($format); InUse = $_.InUse; Seats = $_.Seats }
                            })
                    }
                })
        }

        'denials' {
            $denials = @(Get-FathomDenial @server @feature @period)
            $last = { ($_.Group.Time | Measure-Object -Maximum).Maximum }
            $total = { ($_.Group.Licenses | Measure-Object -Sum).Sum }
            switch ($values.group) {
                'event' {
                    $rows = $denials | Select-Object Time, @{ Name = 'Server'; Expression = 'ServerId' }, Feature, User, Host, Licenses
                    $columns = [ordered] @{ Time = 'Time'; Feature = 'Feature'; User = 'User'; Host = 'Host'; Licenses = 'Licenses'; Server = 'Server' }
                }
                'feature' {
                    $rows = $denials | Group-Object ServerId, Feature | ForEach-Object {
                        [pscustomobject] @{
                            Server  = $_.Group[0].ServerId
                            Feature = $_.Group[0].Feature
                            Denials = & $total
                            Users   = @($_.Group.User | Sort-Object -Unique).Count
                            Last    = & $last
                        }
                    } | Sort-Object Denials -Descending
                    $columns = [ordered] @{ Feature = 'Feature'; Denials = 'Denials'; Users = 'Users denied'; Last = 'Last denied'; Server = 'Server' }
                }
                'user' {
                    $rows = $denials | Group-Object User | ForEach-Object {
                        [pscustomobject] @{
                            User     = $_.Group[0].User
                            Denials  = & $total
                            Features = @($_.Group.Feature | Sort-Object -Unique).Count
                            Last     = & $last
                        }
                    } | Sort-Object Denials -Descending
                    $columns = [ordered] @{ User = 'User'; Denials = 'Denials'; Features = 'Features'; Last = 'Last denied' }
                }
            }
        }

        'top-users' {
            $rows = Get-FathomTopUser @server @feature @period -Top $values.top
            $columns = [ordered] @{ User = 'User'; Hours = 'Hours held'; Features = 'Features'; Checkouts = 'Checkouts'; Denials = 'Denials' }
        }

        'expiring' {
            $rows = Get-FathomExpiry -WithinDays $values.days -IncludeExpired:($values.expired -eq 'show') |
                Where-Object { -not $values.server -or $_.ServerId -eq $values.server }
            $columns = [ordered] @{ Feature = 'Feature'; Vendor = 'Vendor'; Seats = 'Seats'; Expires = 'Expires'; DaysLeft = 'Days left'; Server = 'Server' }
        }

        'uptime' {
            $rows = Get-FathomServerUptime @server @period | ForEach-Object {
                [pscustomobject] @{
                    Server        = $_.ServerId
                    UptimePercent = $_.UptimePercent
                    Polls         = $_.Polls
                    Outages       = $_.Outages
                    LongestHours  = if ($_.LongestOutage) { [Math]::Round($_.LongestOutage.TotalHours, 1) } else { 0 }
                }
            }
            $columns = [ordered] @{ Server = 'Server'; UptimePercent = 'Uptime (%)'; Polls = 'Polls'; Outages = 'Outages'; LongestHours = 'Longest outage (hours)' }
        }

        'seat-holders' {
            $rows = Get-FathomLicenseHolder @server @feature |
                Where-Object { -not $values.hours -or $_.Hours -ge $values.hours } |
                Sort-Object Hours -Descending |
                Select-Object User, Feature, Host, Licenses, @{ Name = 'Since'; Expression = 'StartedAt' }, Hours, @{ Name = 'Server'; Expression = 'ServerId' }
            $columns = [ordered] @{ User = 'User'; Feature = 'Feature'; Host = 'Host'; Licenses = 'Seats'; Since = 'Since'; Hours = 'Hours'; Server = 'Server' }
        }
    }

    # What was asked for, printed at the top of an export so a file explains itself.
    $asked = foreach ($spec in $definition.Options) {
        $value = $values[$spec.Name]
        if ($spec.Kind -eq 'Choice') { $value = $spec.Choices[$value] }
        if ($value -or $value -is [int]) { "$($spec.Label -replace ' \(blank.*\)'): $($value -join ', ')" }
    }
    $window = if ($definition.Presets) { '{0:yyyy-MM-dd HH:mm} to {1:yyyy-MM-dd HH:mm}' -f $From, $To } else { 'As of {0:yyyy-MM-dd HH:mm}' -f (Get-Date) }

    [pscustomobject] @{
        PSTypeName = 'Fathom.Report'
        Name       = $definition.Name
        Title      = $definition.Title
        Summary    = @($window; $asked) -join '; '
        Options    = $values
        Columns    = $columns
        Rows       = @($rows)
        Charts     = $charts
    }
}
