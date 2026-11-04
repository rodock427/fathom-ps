function Start-FathomTransaction {
    <#
    .SYNOPSIS
        Starts a transaction on this runspace's connection; commands join it until it completes or is undone.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $session = Get-FathomSession
    if ($PSCmdlet.ShouldProcess('Fathom database', 'Start a transaction')) {
        $session.Transaction = $session.Connection.BeginTransaction()
    }
}
