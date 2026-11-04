function Use-FathomDatabase {
    <#
    .SYNOPSIS
        Runs a script block with the database connected, then disconnects.
    .DESCRIPTION
        For PSU app pages and event handlers, which each run in a fresh runspace. If a connection
        is already open, it's used and left open.
    .EXAMPLE
        Use-FathomDatabase { Get-FathomAvailability }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [scriptblock] $ScriptBlock,

        # Defaults as Connect-FathomDatabase does.
        [string] $Dsn = (Get-FathomDefaultDsn)
    )

    if (Test-SqlConnection -ConnectionName $script:ConnectionName) {
        return & $ScriptBlock
    }

    Connect-FathomDatabase -Dsn $Dsn
    try {
        & $ScriptBlock
    } finally {
        Disconnect-FathomDatabase
    }
}
