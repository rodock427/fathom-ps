function Get-FathomConnectionName {
    <#
    .SYNOPSIS
        The key of this runspace's database connection in $script:Sessions.
    .DESCRIPTION
        PSU runs concurrent jobs and app pages in one process, and they can share this module's
        state. A runspace runs one thing at a time, so a connection per runspace keeps them from
        ever sharing, replacing or closing each other's.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    "Fathom-$([runspace]::DefaultRunspace.InstanceId.ToString('N'))"
}
