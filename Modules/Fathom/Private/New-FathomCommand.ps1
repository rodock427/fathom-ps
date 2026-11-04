function New-FathomCommand {
    <#
    .SYNOPSIS
        A command on this runspace's connection (in its transaction, if any), with @name parameters.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object in memory; nothing changes.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Query,
        [hashtable] $Parameters = @{},
        [int] $CommandTimeout = 30
    )

    $session = Get-FathomSession
    $command = $session.Connection.CreateCommand()
    $command.CommandText = $Query
    $command.CommandTimeout = $CommandTimeout
    if ($session.Transaction) {
        $command.Transaction = $session.Transaction
    }
    # GetEnumerator, not .Keys: a parameter named "keys" would shadow the hashtable's own Keys.
    # Plain assignments throughout, so a typed array reaches Npgsql as that array.
    foreach ($entry in $Parameters.GetEnumerator()) {
        $value = $entry.Value
        if ($value -isnot [array] -and $null -eq $value) {
            $value = [DBNull]::Value
        }
        $null = $command.Parameters.AddWithValue($entry.Key, $value)
    }
    $command
}
