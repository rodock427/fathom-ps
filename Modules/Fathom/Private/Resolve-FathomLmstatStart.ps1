function Resolve-FathomLmstatStart {
    <#
    .SYNOPSIS
        Turns an lmstat holder start ("start Mon 11/2 9:41", no year) into a full date.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)] [int] $Month,
        [Parameter(Mandatory)] [int] $Day,
        [Parameter(Mandatory)] [int] $Hour,
        [Parameter(Mandatory)] [int] $Minute,
        [Parameter(Mandatory)] [datetime] $CapturedAt
    )

    # A session can't start after it was seen (a day's grace for clock skew), so a later
    # date means last year: a checkout from 12/28 seen on 1/2. Trying last year also covers
    # a Feb 29 start seen in a non-leap year.
    foreach ($year in $CapturedAt.Year, ($CapturedAt.Year - 1)) {
        if ($Day -gt [datetime]::DaysInMonth($year, $Month)) {
            continue
        }
        $started = [datetime]::new($year, $Month, $Day, $Hour, $Minute, 0)
        if ($started -le $CapturedAt.AddDays(1)) {
            return $started
        }
    }
}
