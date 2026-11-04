function Resolve-FathomTimestamp {
    <#
    .SYNOPSIS
        Combines the running log date with a line's time of day, moving the date on at midnight.
    .DESCRIPTION
        lmgrd stamps most lines with a time only, and re-states the date in occasional TIMESTAMP
        lines. When the time jumps back by more than 12 hours since the previous line, the log
        has crossed midnight, so the running date moves on a day. A smaller step back is a clock
        change (daylight saving falling back an hour), not a new day. Python Fathom doesn't
        roll over, so it dates after-midnight lines a day early until the next TIMESTAMP.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)] [PSTypeName('Fathom.ParserContext')] $Context,
        [Parameter(Mandatory)] [string] $Time
    )

    $timeOfDay = [datetime]::ParseExact($Time, 'H:mm:ss', [cultureinfo]::InvariantCulture).TimeOfDay

    if ($Context.CurrentDate -and $null -ne $Context.LastTime -and ($Context.LastTime - $timeOfDay).TotalHours -gt 12) {
        $Context.CurrentDate = $Context.CurrentDate.AddDays(1)
    }
    $Context.LastTime = $timeOfDay

    # No date marker seen yet: fall back to today, as Fathom does.
    $day = if ($Context.CurrentDate) { $Context.CurrentDate.Date } else { (Get-Date).Date }
    $day + $timeOfDay
}
