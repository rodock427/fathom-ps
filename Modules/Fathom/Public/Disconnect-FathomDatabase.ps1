function Disconnect-FathomDatabase {
    <#
    .SYNOPSIS
        Closes this runspace's Fathom database connection, if one is open.
    #>
    [CmdletBinding()]
    param()

    $session = $null
    if ($script:Sessions.TryRemove((Get-FathomConnectionName), [ref] $session)) {
        $session.Connection.Dispose()
    }
}
