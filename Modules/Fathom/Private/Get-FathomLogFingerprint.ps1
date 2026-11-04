function Get-FathomLogFingerprint {
    <#
    .SYNOPSIS
        Identifies a log file by a hash of its first line, or returns $null until that line is complete.
    .DESCRIPTION
        Stands in for Fathom's device:inode identity, which SMB doesn't expose. lmgrd's first
        line is its startup banner, stamped with date and time, so a replaced or truncated log
        gets a new fingerprint while an appended one keeps its own.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [System.IO.Stream] $Stream
    )

    $buffer = [byte[]]::new(64KB)
    $Stream.Position = 0
    $read = $Stream.ReadAtLeast($buffer, $buffer.Length, $false)

    # Hashing a half-written first line would give a growing file a new identity on every read.
    $end = [Array]::IndexOf($buffer, [byte] 10, 0, $read)
    if ($end -lt 0) {
        return $null
    }

    $firstLine = [byte[]]::new($end + 1)
    [Array]::Copy($buffer, $firstLine, $firstLine.Length)
    $hash = [System.Security.Cryptography.SHA256]::HashData($firstLine)
    [System.Convert]::ToHexString($hash).Substring(0, 16).ToLowerInvariant()
}
