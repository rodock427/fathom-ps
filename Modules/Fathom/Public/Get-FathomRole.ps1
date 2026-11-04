function Get-FathomRole {
    <#
    .SYNOPSIS
        The PSU roles that reach an access tier: Reader (totals), Operator (individuals), Admin (manage).
    .DESCRIPTION
        Each tier includes the ones below it, and PSU's own Administrator reaches every tier.
        Map the Fathom roles to directory groups in PSU (Security, Roles).
    .EXAMPLE
        New-UDPage -Name 'People' -Role (Get-FathomRole -Tier Operator) -Content { }
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Reader', 'Operator', 'Admin')]
        [string] $Tier
    )

    $tiers = 'Reader', 'Operator', 'Admin'
    $from = $tiers.IndexOf($Tier)
    @($tiers[$from..2] | ForEach-Object { "Fathom$_" }) + 'Administrator'
}
