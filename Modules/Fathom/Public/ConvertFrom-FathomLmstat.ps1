function ConvertFrom-FathomLmstat {
    <#
    .SYNOPSIS
        Parses `lmutil lmstat -a` output into a live usage snapshot per feature, with its holders and expiry.
    .DESCRIPTION
        Reads the "Users of <feature>: (Total of N licenses issued; Total of M licenses in use)"
        line, the vendor line after it (daemon and expiry), and one line per current holder.
        Output with no feature lines (an unreachable server, say) produces nothing rather than
        an error. Feature, seats and vendor match Python Fathom; holders and expiry are additions.
    .EXAMPLE
        & lmutil lmstat -a -c 27000@licsrv01 | ConvertFrom-FathomLmstat -ServerId licsrv01
    #>
    [CmdletBinding()]
    [OutputType('Fathom.LiveFeatureStatus')]
    param(
        # lmstat output: one line per item, or the whole text as one string.
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string[]] $InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ServerId,

        # When the output was captured. Holder start times carry no year; it's inferred from this.
        [datetime] $CapturedAt = (Get-Date)
    )

    begin {
        $usageRegex = [regex] 'Users of (?<feature>\S+):\s+\(Total of (?<issued>\d+) licenses? issued;\s+Total of (?<inUse>\d+) licenses? in use\)'
        $vendorRegex = [regex] 'vendor:\s*(?<vendor>\S+),'
        $expiryRegex = [regex] 'expiry:\s*(?<expiry>[^,\s]+)'
        # e.g. "    bob ws-02 ws-02 (v1.0) (licsrv01/27000 2202), start Mon 11/2 9:41, 2 licenses"
        $holderRegex = [regex] (
            '^\s+(?<user>\S+)\s+(?<host>\S+)\s+(?<display>\S+)\s+\((?<version>[^)]*)\)\s+' +
            '\(\S+?/\d+\s+(?<handle>\d+)\),\s+start\s+\w+\s+(?<month>\d{1,2})/(?<day>\d{1,2})\s+' +
            '(?<hour>\d{1,2}):(?<minute>\d{2})(?:,\s+(?<count>\d+)\s+licenses?)?')
        $invariant = [cultureinfo]::InvariantCulture
        $current = $null
    }

    process {
        foreach ($text in $InputObject -split '\r\n|\n|\r') {
            $usage = $usageRegex.Match($text)
            if ($usage.Success) {
                # A feature is complete once the next one starts.
                if ($current) {
                    $current
                }
                $current = [pscustomobject] @{
                    PSTypeName     = 'Fathom.LiveFeatureStatus'
                    ServerId       = $ServerId
                    Feature        = $usage.Groups['feature'].Value
                    LicensesIssued = [int] $usage.Groups['issued'].Value
                    LicensesInUse  = [int] $usage.Groups['inUse'].Value
                    VendorDaemon   = $null
                    # $null with ExpiryReported = never expires; $null without it = lmstat didn't say.
                    Expiry         = $null
                    ExpiryReported = $false
                    Holders        = [System.Collections.Generic.List[object]]::new()
                    CapturedAt     = $CapturedAt
                }
                continue
            }
            if (-not $current) {
                continue
            }

            if (-not $current.VendorDaemon) {
                $vendor = $vendorRegex.Match($text)
                if ($vendor.Success) {
                    $current.VendorDaemon = $vendor.Groups['vendor'].Value

                    $expiry = $expiryRegex.Match($text).Groups['expiry'].Value
                    $date = [datetime]::MinValue
                    # 'permanent' and year 0000 are FlexLM's two spellings of "never expires".
                    if ($expiry -eq 'permanent' -or $expiry -match '-0+$') {
                        $current.ExpiryReported = $true
                    } elseif ([datetime]::TryParseExact($expiry, 'd-MMM-yyyy', $invariant, 'None', [ref] $date)) {
                        $current.Expiry = $date
                        $current.ExpiryReported = $true
                    }
                    continue
                }
            }

            $holder = $holderRegex.Match($text)
            if ($holder.Success) {
                $start = @{
                    Month  = [int] $holder.Groups['month'].Value
                    Day    = [int] $holder.Groups['day'].Value
                    Hour   = [int] $holder.Groups['hour'].Value
                    Minute = [int] $holder.Groups['minute'].Value
                }
                $current.Holders.Add([pscustomobject] @{
                        PSTypeName = 'Fathom.LicenseHolder'
                        User       = $holder.Groups['user'].Value
                        Host       = $holder.Groups['host'].Value
                        Display    = $holder.Groups['display'].Value
                        Version    = $holder.Groups['version'].Value
                        Handle     = $holder.Groups['handle'].Value
                        Licenses   = if ($holder.Groups['count'].Success) { [int] $holder.Groups['count'].Value } else { 1 }
                        StartedAt  = Resolve-FathomLmstatStart @start -CapturedAt $CapturedAt
                    })
            }
        }
    }

    end {
        if ($current) {
            $current
        }
    }
}
