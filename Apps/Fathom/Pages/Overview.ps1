# Everyone: is a seat free, is everything up, is anything expiring. Operators also see the last
# day's denials.
. "$PSScriptRoot/../Common.ps1"

if (-not (Test-FathomAccess -Tier Reader -Role $Roles)) {
    return New-FathomNotAuthorized
}

$operator = Test-FathomAccess -Tier Operator -Role $Roles
# The period for denials; everything else on this page is now.
$presets = 1, 7, 30
$timeframe = Get-FathomTimeframe -Query $Query -Presets $presets -DefaultDays 1
$severity = @{ Critical = 'error'; Warning = 'warning'; Info = 'info' }

Use-FathomDatabase {
    $settings = Get-FathomAlertSetting

    New-UDTypography -Variant h4 -Text 'License overview' -GutterBottom
    foreach ($alert in Get-FathomAlert) {
        New-UDAlert -Severity $severity[$alert.Severity] -Text $alert.Message -Dense
    }

    New-UDGrid -Container -Spacing 2 -Children {
        New-UDGrid -Item -ExtraSmallSize 12 -Children {
            New-UDCard -Title 'Servers' -Content {
                $rows = foreach ($server in Get-FathomServerHealth) {
                    $notes = @(
                        if ($server.DaemonsDown) { "vendor daemon down: $($server.DaemonsDown -join ', ')" }
                        if ($server.PollStale) { 'lmstat poll is overdue' }
                        if ($server.LogStatus -eq 'Unreachable') { 'debug log unreachable' }
                        if ($server.LogStale) { 'debug log has gone quiet' }
                        if ($server.LogDrifted) { 'debug log disagrees with lmstat' }
                    )
                    [pscustomobject] @{
                        ServerId  = $server.ServerId
                        Server    = $server.Name
                        Status    = $server.Status
                        Color     = Get-FathomStatusColor $server.Status
                        LastPoll  = Format-FathomTime $server.LastPolled
                        SeatsUsed = $server.SeatsInUse
                        Source    = $server.EffectiveSource
                        Notes     = $notes -join '; '
                    }
                }
                $table = @{
                    Id      = 'overview-servers'
                    Data    = $rows
                    Columns = [ordered] @{ Server = 'Server'; Status = 'Status'; SeatsUsed = 'Seats in use'; LastPoll = 'Last poll'; Source = 'Usage from'; Notes = 'Notes' }
                    Render  = @{
                        Server = { New-UDLink -Text $EventData.Server -Url "server?id=$($EventData.ServerId)" }
                        Status = { New-UDChip -Label $EventData.Status -Color $EventData.Color -Size small }
                    }
                    Empty   = 'No servers are monitored yet.'
                }
                New-FathomTable @table
            }
        }

        New-UDGrid -Item -ExtraSmallSize 12 -LargeSize 8 -Children {
            New-UDCard -Title 'Free seats' -Content {
                $rows = Get-FathomAvailability | Sort-Object Server, Feature | ForEach-Object {
                    [pscustomobject] @{
                        Server  = $_.Server
                        Feature = $_.Feature
                        Free    = $_.Free
                        InUse   = '{0} of {1}' -f $_.InUse, $_.Issued
                        Expires = $_.Expires ? $_.Expires.ToString('yyyy-MM-dd') : 'permanent'
                    }
                }
                $table = @{
                    Id      = 'overview-availability'
                    Data    = $rows
                    Columns = [ordered] @{ Feature = 'Feature'; Free = 'Free'; InUse = 'In use'; Server = 'Server'; Expires = 'Expires' }
                    Render  = @{
                        Free = { New-UDChip -Label ([string] $EventData.Free) -Color ($EventData.Free ? 'success' : 'error') -Size small }
                    }
                    Empty   = 'No lmstat data yet.'
                }
                New-FathomTable @table
            }
        }

        New-UDGrid -Item -ExtraSmallSize 12 -LargeSize 4 -Children {
            New-UDCard -Title "Expiring within $($settings.ExpiryDays) days" -Content {
                $rows = Get-FathomExpiry -WithinDays $settings.ExpiryDays -IncludeExpired | ForEach-Object {
                    # Three short columns: this card is a third of the page wide.
                    $left = if ($_.DaysLeft -lt 0) { 'expired' } else { "$($_.DaysLeft) days" }
                    [pscustomobject] @{
                        Feature = $_.Feature
                        Server  = $_.Server
                        Expires = "$($_.Expires.ToString('yyyy-MM-dd')) ($left)"
                    }
                }
                $table = @{
                    Id      = 'overview-expiry'
                    Data    = $rows
                    Columns = [ordered] @{ Feature = 'Feature'; Expires = 'Expires'; Server = 'Server' }
                    Empty   = 'Nothing is about to expire.'
                }
                New-FathomTable @table
            }
        }

        if ($operator) {
            New-UDGrid -Item -ExtraSmallSize 12 -Children {
                New-UDCard -Title "Denied in $($timeframe.Label)" -Content {
                    New-FathomTimeframePicker -Timeframe $timeframe -Presets $presets -Page 'overview'
                    $rows = Get-FathomDenial -From $timeframe.From -To $timeframe.To | ForEach-Object {
                        [pscustomobject] @{
                            Time    = Format-FathomTime $_.Time
                            Server  = $_.ServerId
                            Feature = $_.Feature
                            User    = $_.User
                            Host    = $_.Host
                        }
                    }
                    $table = @{
                        Id      = 'overview-denials'
                        Data    = $rows
                        Columns = [ordered] @{ Time = 'Time'; Feature = 'Feature'; User = 'User'; Host = 'Host'; Server = 'Server' }
                        Render  = @{ User = { New-UDLink -Text $EventData.User -Url "people?user=$([uri]::EscapeDataString($EventData.User))" } }
                        Empty   = 'No denials in this period (servers without a readable debug log cannot report them).'
                    }
                    New-FathomTable @table
                }
            }
        }
    }
}
