function ConvertTo-FathomQueryString {
    <#
    .SYNOPSIS
        A query string from a hashtable, leaving out empty values.
    .DESCRIPTION
        In the module so that page event handlers can use it: they can't see the helpers in Common.ps1.
    .EXAMPLE
        ConvertTo-FathomQueryString @{ days = 7; id = 'licsrv01' }
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([hashtable] $Query = @{})

    ($Query.GetEnumerator() | Where-Object { $null -ne $_.Value -and '' -ne $_.Value } | Sort-Object Key | ForEach-Object {
        '{0}={1}' -f $_.Key, [uri]::EscapeDataString([string] $_.Value)
    }) -join '&'
}
