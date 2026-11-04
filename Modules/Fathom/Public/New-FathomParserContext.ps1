function New-FathomParserContext {
    <#
    .SYNOPSIS
        Creates the running state ConvertFrom-FathomDebugLog needs while walking a log.
    .DESCRIPTION
        Most FlexLM lines carry only a time of day. The date comes from the startup banner
        and periodic TIMESTAMP lines, so the parser carries it forward in CurrentDate, and
        LastTime (the previous line's time) lets it notice midnight. Persist CurrentDate,
        LastTime and LineNumber between reads to resume a log where it stopped.
    .EXAMPLE
        New-FathomParserContext -ServerId licsrv01 -SourceFile '\\licsrv01\flexlm$\debug.log'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    [OutputType('Fathom.ParserContext')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ServerId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SourceFile,

        # Seeds event ids. Defaults to "<ServerId>:<SourceFile>", as Fathom does for pushed logs.
        [string] $SourceHash = "${ServerId}:${SourceFile}",

        # Groups the events written by one read.
        [string] $BatchId = [guid]::NewGuid().ToString('N').Substring(0, 12),

        # Running date carried over from a previous read. Leave empty for a fresh log.
        [Nullable[datetime]] $CurrentDate,

        # Time of day of the last line read before, so a midnight between reads is noticed.
        [Nullable[timespan]] $LastTime,

        # Lines already read; the next line parsed is LineNumber + 1.
        [ValidateRange(0, [long]::MaxValue)]
        [long] $LineNumber = 0
    )

    [pscustomobject] @{
        PSTypeName  = 'Fathom.ParserContext'
        ServerId    = $ServerId
        SourceFile  = $SourceFile
        SourceHash  = $SourceHash
        BatchId     = $BatchId
        CurrentDate = $CurrentDate
        LastTime    = $LastTime
        LineNumber  = $LineNumber
    }
}
