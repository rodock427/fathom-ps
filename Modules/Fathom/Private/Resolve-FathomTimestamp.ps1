function Resolve-FathomTimestamp {
    <#
    .SYNOPSIS
        Combines the running log date with a line's time of day.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Nullable[datetime]] $Date,
        [Parameter(Mandatory)] [string] $Time
    )

    # No date marker seen yet: fall back to today, as Fathom does.
    $day = if ($Date) { $Date.Date } else { (Get-Date).Date }
    $day + [datetime]::ParseExact($Time, 'H:mm:ss', [cultureinfo]::InvariantCulture).TimeOfDay
}
