function ConvertFrom-FathomLmstat {
    <#
    .SYNOPSIS
        Parses `lmutil lmstat -a` output into a live usage snapshot per feature.
    .DESCRIPTION
        Reads the "Users of <feature>: (Total of N licenses issued; Total of M licenses in use)"
        lines, plus the vendor daemon named on the lines that follow each one. Output with no
        feature lines (an unreachable server, say) produces nothing rather than an error.
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

        [datetime] $CapturedAt = (Get-Date)
    )

    begin {
        $usageRegex = [regex] 'Users of (?<feature>\S+):\s+\(Total of (?<issued>\d+) licenses? issued;\s+Total of (?<inUse>\d+) licenses? in use\)'
        $vendorRegex = [regex] 'vendor:\s*(?<vendor>\S+),'
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
                    CapturedAt     = $CapturedAt
                }
            } elseif ($current -and -not $current.VendorDaemon) {
                $vendor = $vendorRegex.Match($text)
                if ($vendor.Success) {
                    $current.VendorDaemon = $vendor.Groups['vendor'].Value
                }
            }
        }
    }

    end {
        if ($current) {
            $current
        }
    }
}
