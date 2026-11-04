function Disconnect-FathomDatabase {
    <#
    .SYNOPSIS
        Closes the Fathom database connection, if one is open.
    #>
    [CmdletBinding()]
    param()

    if (Test-SqlConnection -ConnectionName $script:ConnectionName) {
        Close-SqlConnection -ConnectionName $script:ConnectionName
    }
}
