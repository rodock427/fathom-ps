function Complete-FathomTransaction {
    <#
    .SYNOPSIS
        Commits this runspace's transaction.
    #>
    [CmdletBinding()]
    param()

    $session = Get-FathomSession
    try {
        $session.Transaction.Commit()
    } finally {
        $session.Transaction.Dispose()
        $session.Transaction = $null
    }
}
