function Get-FathomEventId {
    <#
    .SYNOPSIS
        Deterministic event id, so re-reading the same line is always deduplicated.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $SourceHash,
        [Parameter(Mandatory)] [long] $LineNumber,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $RawLine
    )

    # Same recipe as Fathom's LicenseEvent.make_event_id, so both apps agree on ids.
    $bytes = [System.Text.Encoding]::UTF8.GetBytes("${SourceHash}:${LineNumber}:${RawLine}")
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    [System.Convert]::ToHexString($hash).Substring(0, 32).ToLowerInvariant()
}
