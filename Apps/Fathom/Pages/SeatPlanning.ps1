# Seat planning (Reports): per feature over a period, too many seats or too few? Operators only.
. "$PSScriptRoot/../Common.ps1"

if (-not (Test-FathomAccess -Tier Operator -Role $Roles)) {
    return New-FathomNotAuthorized
}

$presets = 30, 90, 365
$timeframe = Get-FathomTimeframe -Query $Query -Presets $presets -DefaultDays 90

Use-FathomDatabase {
    $servers = @(Get-FathomServer | Sort-Object Name)
    $serverId = ($servers | Where-Object ServerId -EQ $Query.server | Select-Object -First 1).ServerId
    $window = $timeframe.Query

    New-UDTypography -Variant h4 -Text 'Seat planning' -GutterBottom
    New-UDStack -Direction column -Spacing 1 -Children {
        # One server at a time keeps the list short where servers carry hundreds of features.
        New-UDSelect -Id 'seat-planning-server' -Label 'Server' -DefaultValue ($serverId ?? 'all') -Option {
            New-UDSelectOption -Name 'All servers' -Value 'all'
            foreach ($server in $servers) {
                New-UDSelectOption -Name $server.Name -Value $server.ServerId
            }
        } -OnChange {
            $server = if ($EventData -ne 'all') { [string] $EventData }
            Invoke-UDRedirect -Url "seat-planning?$(ConvertTo-FathomQueryString ($window + @{ server = $server }))"
        }
        New-FathomTimeframePicker -Timeframe $timeframe -Presets $presets -Page 'seat-planning' -Keep @{ server = $serverId }
        New-UDTypography -Variant body2 -Text (
            'Typical is the 95th percentile of seats in use. Denials and users denied need a readable debug log; ' +
            'underused means the peak stayed under half the seats.')
    }

    # ponytail: 5-minute buckets; a year on a server with hundreds of features is slow (an hourly rollup is in PLAN.md).
    $report = @{ From = $timeframe.From; To = $timeframe.To }
    if ($serverId) { $report.ServerId = $serverId }
    $rows = foreach ($row in Get-FathomCapacityReport @report | Sort-Object ServerId, Feature) {
        $flags = @(
            if ($row.Underused) { 'underused' }
            if ($row.Denials) { 'turning users away' }
        )
        [pscustomobject] @{
            Server      = $row.ServerId
            Feature     = $row.Feature
            Seats       = $row.Seats
            Peak        = $row.Peak
            Typical     = if ($null -ne $row.P95) { [Math]::Round($row.P95, 1) }
            AtCapacity  = if ($null -ne $row.AtCapacityPercent) { "$($row.AtCapacityPercent)%" }
            Denials     = $row.Denials
            DeniedUsers = $row.DeniedUsers
            ActiveUsers = $row.ActiveUsers
            Flags       = $flags -join ', '
        }
    }
    $table = @{
        Id         = 'capacity-report'
        Data       = $rows
        Columns    = [ordered] @{
            Feature     = 'Feature'
            Seats       = 'Seats'
            Peak        = 'Peak'
            Typical     = 'Typical'
            AtCapacity  = 'Time at capacity'
            Denials     = 'Denials'
            DeniedUsers = 'Users denied'
            ActiveUsers = 'Active users'
            Flags       = 'Flags'
            Server      = 'Server'
        }
        Empty      = 'No usage recorded in this period.'
        ShowExport = $true
    }
    New-FathomTable @table
}
