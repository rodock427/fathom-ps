function ConvertFrom-FathomDbValue {
    <#
    .SYNOPSIS
        A value read from Postgres as the rest of Fathom expects it: NULL as $null, a date as a DateTime.
    .DESCRIPTION
        Npgsql returns a date column as DateOnly or DateTime depending on how it was configured
        (SimplySql's copy differs from a fresh one), and DateOnly can't be subtracted.
    #>
    [CmdletBinding()]
    [OutputType([object], [array], [datetime], [timespan])]
    param([AllowNull()] $Value)

    if ($Value -is [DBNull]) {
        return $null
    }
    if ($Value -is [DateOnly]) {
        return $Value.ToDateTime([TimeOnly]::MinValue)
    }
    if ($Value -is [TimeOnly]) {
        return $Value.ToTimeSpan()
    }
    # The comma keeps an array (a Postgres array column) an array.
    , $Value
}
