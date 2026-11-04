function Get-FathomLmstatHealth {
    <#
    .SYNOPSIS
        Reads lmgrd's own status and each vendor daemon's from lmstat output.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Output
    )

    $inDaemonSection = $false
    $daemons = foreach ($line in $Output -split '\r\n|\n|\r') {
        if ($line -match '^Vendor daemon status') {
            $inDaemonSection = $true
        } elseif ($line -match '^Feature usage info') {
            $inDaemonSection = $false
        } elseif ($inDaemonSection -and $line -match '^\s*(?<name>[^\s:]+):\s*(?<detail>.+?)\s*$') {
            # "adskflex: UP v11.19.4" or "mlm: The desired vendor daemon is down. (-97,121)"
            # Copy out first: the -match below would overwrite $Matches.
            $name, $detail = $Matches['name'], $Matches['detail']
            [pscustomobject] @{
                Name   = $name
                Up     = $detail -match '^UP\b'
                Detail = $detail
            }
        }
    }

    [pscustomobject] @{
        ServerUp = $Output -match 'license server UP'
        Daemons  = @($daemons)
    }
}
