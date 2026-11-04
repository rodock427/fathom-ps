function ConvertTo-FathomSqlTime {
    <#
    .SYNOPSIS
        Formats a time the way every Fathom table stores it: local, no time zone, to the second.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] [datetime] $Time
    )

    process {
        $Time.ToString('yyyy-MM-dd HH:mm:ss')
    }
}
