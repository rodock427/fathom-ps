# FlexLM debug-log rules, ported from Fathom's lm_parsers/flexlm (patterns.py + parser.py).
# First match wins, so order matters. Keep it identical to Fathom's or parity breaks.
$script:FlexLMRules = & {
    $fragments = @{
        '{TIME}'      = '(?<time>\d{1,2}:\d{2}:\d{2})'
        '{DATE}'      = '(?<date>\d{1,2}/\d{1,2}/\d{4})'
        '{USER_HOST}' = '"(?<feature>\S+)"\s+(?<user>\S+)@(?<host>\S+)'
        '{COUNT}'     = '(?:\s*\((?<count>\d+)\s+licenses?\))?'
    }

    # EventType $null = a directive that only moves the running date (TIMESTAMP).
    $rules = @(
        @{ EventType = $null; SetsDate = $true; Pattern = '^\s*{TIME}\s+\((?<daemon>\S+)\)\s+TIMESTAMP\s+{DATE}' }
        @{ EventType = 'server_up'; SetsDate = $true; Pattern = '^\s*{TIME}\s+\(lmgrd\)\s+.*started on\s+\S+\s+.*\({DATE}\)' }
        @{ EventType = 'vendor_daemon_up'; Pattern = '^\s*{TIME}\s+\(lmgrd\)\s+Started\s+(?<vendor>\S+)\s+\(pid' }
        @{ EventType = 'vendor_daemon_down'; Pattern = '^\s*{TIME}\s+\((?<vendor>\S+)\)\s+(?:EXITING|Vendor daemon.*exit)' }
        @{ EventType = 'server_down'; Pattern = '^\s*{TIME}\s+\(lmgrd\)\s+(?:shutdown|EXITING DUE TO SIGNAL)' }
        @{ EventType = 'server_reread'; Pattern = '^\s*{TIME}\s+\(lmgrd\)\s+.*[Rr]e-reading license' }
        @{ EventType = 'checkout'; Pattern = '^\s*{TIME}\s+\((?<vendor>\S+)\)\s+OUT:\s+{USER_HOST}{COUNT}' }
        @{ EventType = 'checkin'; Pattern = '^\s*{TIME}\s+\((?<vendor>\S+)\)\s+IN:\s+{USER_HOST}{COUNT}' }
        @{ EventType = 'denied'; Pattern = '^\s*{TIME}\s+\((?<vendor>\S+)\)\s+DENIED:\s+{USER_HOST}' }
        @{ EventType = 'queued'; Pattern = '^\s*{TIME}\s+\((?<vendor>\S+)\)\s+QUEUED:\s+{USER_HOST}' }
        @{ EventType = 'license_expired'; Pattern = '^\s*{TIME}\s+\((?<vendor>\S+)\)\s+.*"(?<feature>\S+)".*[Ee]xpired' }
    )

    foreach ($rule in $rules) {
        $pattern = $rule.Pattern
        foreach ($token in $fragments.Keys) {
            $pattern = $pattern.Replace($token, $fragments[$token])
        }
        [pscustomobject] @{
            EventType = $rule.EventType
            SetsDate  = [bool] $rule.SetsDate
            Regex     = [regex]::new($pattern, 'Compiled, CultureInvariant')
        }
    }
}

# Fallback for unmatched lines, so they keep their logged time instead of midnight.
$script:LeadingTimeRegex = [regex]::new('^\s*(?<time>\d{1,2}:\d{2}:\d{2})', 'Compiled, CultureInvariant')
