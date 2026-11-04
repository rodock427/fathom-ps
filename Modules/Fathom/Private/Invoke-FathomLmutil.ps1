function Invoke-FathomLmutil {
    <#
    .SYNOPSIS
        Runs lmutil with a hard timeout and returns its exit code and combined output.
    .DESCRIPTION
        lmutil can wait a long time on an unreachable license server; the timeout keeps
        one bad server from holding up a whole scheduled run.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string[]] $ArgumentList,
        [Parameter(Mandatory)] [int] $TimeoutSeconds
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($Path)
    foreach ($argument in $ArgumentList) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        # Read both streams asynchronously so neither pipe can fill up and stall lmutil.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()

        $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut) {
            $process.Kill($true)
        }
        $process.WaitForExit()

        [pscustomobject] @{
            TimedOut = $timedOut
            ExitCode = if ($timedOut) { $null } else { $process.ExitCode }
            Output   = $stdout.Result + $stderr.Result
        }
    } finally {
        $process.Dispose()
    }
}
