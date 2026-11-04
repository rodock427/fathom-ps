function Undo-FathomTransaction {
    <#
    .SYNOPSIS
        Rolls back this runspace's transaction, if one is running.
    #>
    [CmdletBinding()]
    param()

    $session = Get-FathomSession
    if ($session.Transaction) {
        try {
            $session.Transaction.Rollback()
        } finally {
            $session.Transaction.Dispose()
            $session.Transaction = $null
        }
    }
}
