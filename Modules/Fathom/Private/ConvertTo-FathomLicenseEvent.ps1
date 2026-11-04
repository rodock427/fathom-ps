function ConvertTo-FathomLicenseEvent {
    <#
    .SYNOPSIS
        Builds one license event from a log line, filling bookkeeping fields from the context.
    #>
    [CmdletBinding()]
    [OutputType('Fathom.LicenseEvent')]
    param(
        [Parameter(Mandatory)] [string] $Line,
        [Parameter(Mandatory)] [string] $EventType,
        [Parameter(Mandatory)] [datetime] $Timestamp,
        [Parameter(Mandatory)] [PSTypeName('Fathom.ParserContext')] $Context,

        # The rule's match, if any. Named groups that took part become fields.
        [System.Text.RegularExpressions.Match] $Match
    )

    $captured = @{}
    if ($Match) {
        foreach ($name in 'feature', 'vendor', 'user', 'host', 'count') {
            if ($Match.Groups[$name].Success) {
                $captured[$name] = $Match.Groups[$name].Value
            }
        }
    }

    [pscustomobject] @{
        PSTypeName        = 'Fathom.LicenseEvent'
        EventId           = Get-FathomEventId -SourceHash $Context.SourceHash -LineNumber $Context.LineNumber -RawLine $Line
        EventType         = $EventType
        Timestamp         = $Timestamp
        ServerFormat      = 'flexlm'
        ServerId          = $Context.ServerId
        Feature           = $captured['feature']
        VendorDaemon      = $captured['vendor']
        User              = $captured['user']
        Host              = $captured['host']
        Display           = $null
        Version           = $null
        LicensesInUse     = $null
        LicensesAvailable = $null
        QueuePosition     = $null
        Handle            = $null
        # "(3 licenses)" claims three seats at once; aggregations sum this, not rows.
        UnitCount         = if ($captured['count']) { [int] $captured['count'] } else { 1 }
        RawLine           = $Line
        SourceFile        = $Context.SourceFile
        LineNumber        = $Context.LineNumber
        IngestBatchId     = $Context.BatchId
    }
}
