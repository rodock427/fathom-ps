function Import-FathomDebugLog {
    <#
    .SYNOPSIS
        Reads an existing lmgrd debug log file into a server's history, once.
    .DESCRIPTION
        For a copy or an old log: it doesn't become the server's live log, so nothing watches it
        afterwards or reports it as gone quiet. Usage history uses it where it has lines and
        lmstat everywhere else. Safe to run again: it carries on from where the last run
        stopped, so an interrupted import loses nothing and a finished one adds nothing. Two
        files covering the same dates would be counted twice.
    .EXAMPLE
        Import-FathomDebugLog -ServerId licsrv01 -Path /data/logs/licsrv01-2025.log
    #>
    [CmdletBinding()]
    [OutputType('Fathom.SyncResult')]
    param(
        [Parameter(Mandatory)]
        [string] $ServerId,

        # A path the PSU server can read: a local file or a share.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    if (-not (Get-FathomServer -ServerId $ServerId)) {
        throw "Server '$ServerId' isn't registered."
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Can't find or read '$Path' from the PSU server."
    }

    # A copy can begin mid-way between lmgrd's date markers. Those first lines belong to the
    # first marker's day, near enough, not to today.
    $marker = Select-String -LiteralPath $Path -Pattern 'TIMESTAMP (\d{1,2}/\d{1,2}/\d{4})|started on .*\((\d{1,2}/\d{1,2}/\d{4})\)' -List
    $sync = @{ ServerId = $ServerId; LogPath = $Path }
    if ($marker) {
        $date = $marker.Matches[0].Groups[1].Value + $marker.Matches[0].Groups[2].Value
        $sync.StartDate = [datetime]::ParseExact($date, 'M/d/yyyy', [cultureinfo]::InvariantCulture)
    }
    Sync-FathomDebugLog @sync
}
