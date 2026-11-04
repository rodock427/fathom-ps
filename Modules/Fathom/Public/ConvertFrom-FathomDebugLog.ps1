function ConvertFrom-FathomDebugLog {
    <#
    .SYNOPSIS
        Parses FlexLM lmgrd debug-log lines into license events.
    .DESCRIPTION
        Emits one event per recognised line. Lines no rule matches are kept as 'unsupported'
        events rather than dropped, so gaps in parser coverage stay visible. Blank lines and
        TIMESTAMP directives emit nothing, but still advance the context.
    .EXAMPLE
        $context = New-FathomParserContext -ServerId licsrv01 -SourceFile debug.log
        [System.IO.File]::ReadLines('debug.log') | ConvertFrom-FathomDebugLog -Context $context
    #>
    [CmdletBinding()]
    [OutputType('Fathom.LicenseEvent')]
    param(
        # Log lines, without line endings.
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string[]] $Line,

        # Running state from New-FathomParserContext. LineNumber and CurrentDate advance as lines are read.
        [Parameter(Mandatory)]
        [PSTypeName('Fathom.ParserContext')]
        $Context
    )

    process {
        foreach ($raw in $Line) {
            $Context.LineNumber++
            if ([string]::IsNullOrWhiteSpace($raw)) {
                continue
            }

            foreach ($rule in $script:FlexLMRules) {
                $match = $rule.Regex.Match($raw)
                if ($match.Success) {
                    break
                }
            }

            $fields = @{ Line = $raw; Context = $Context }

            if ($match.Success) {
                if ($rule.SetsDate) {
                    $Context.CurrentDate = [datetime]::ParseExact($match.Groups['date'].Value, 'M/d/yyyy', [cultureinfo]::InvariantCulture)
                    # The line states its own date, so there's no midnight to detect.
                    $Context.LastTime = $null
                }
                $timestamp = Resolve-FathomTimestamp -Context $Context -Time $match.Groups['time'].Value
                if (-not $rule.EventType) {
                    continue
                }
                $fields.EventType = $rule.EventType
                $fields.Match = $match
                $fields.Timestamp = $timestamp
            } else {
                $fields.EventType = 'unsupported'
                $time = $script:LeadingTimeRegex.Match($raw)
                $fields.Timestamp = if ($time.Success) {
                    Resolve-FathomTimestamp -Context $Context -Time $time.Groups['time'].Value
                } elseif ($Context.CurrentDate) {
                    $Context.CurrentDate
                } else {
                    Get-Date
                }
            }

            ConvertTo-FathomLicenseEvent @fields
        }
    }
}
