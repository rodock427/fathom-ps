# Renewal numbers per feature over a period: too many seats, or too few? Operators only.
. "$PSScriptRoot/../Common.ps1"

if (-not (Test-FathomAccess -Tier Operator -Role $Roles)) {
    return New-FathomNotAuthorized
}

$rangeDays = 30, 90, 365
$days = Get-FathomQueryRange -Value $Query.days -Days $rangeDays -Default 90

Use-FathomDatabase {
    New-UDTypography -Variant h4 -Text 'Capacity and renewal' -GutterBottom
    New-FathomRangePicker -Days $rangeDays -Selected $days -Page 'capacity'
    New-UDTypography -Variant body2 -Text (
        'Typical is the 95th percentile of seats in use. Denials and denied users need a readable debug log; ' +
        'underused means the peak stayed under half the seats.')

    # ponytail: 5-minute buckets make a year's report scan ~105k buckets per feature; fine at
    # this scale. Coarsen IntervalMinutes if the year view gets slow.
    $report = Get-FathomCapacityReport -From (Get-Date).AddDays(-$days) | Sort-Object ServerId, Feature
    $rows = foreach ($row in $report) {
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
