function Get-FathomDirectoryKey {
    <#
    .SYNOPSIS
        How a FlexLM username or host is keyed in the directory tables: lower case, a host
        without its domain (ws-02.corp.local is ws-02).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidateSet('user', 'computer')] [string] $Kind,
        [Parameter(Mandatory, ValueFromPipeline)] [AllowEmptyString()] [string] $Name
    )

    process {
        $key = $Name.Trim().ToLowerInvariant()
        if ($Kind -eq 'computer') {
            $key = $key.Split('.')[0]
        }
        $key
    }
}
