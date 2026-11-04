function Get-FathomSession {
    <#
    .SYNOPSIS
        This runspace's open connection (and transaction, if one is running).
    #>
    [CmdletBinding()]
    param()

    $session = $null
    if (-not $script:Sessions.TryGetValue((Get-FathomConnectionName), [ref] $session)) {
        throw 'Not connected to the Fathom database: run Connect-FathomDatabase first.'
    }
    $session
}
