function Test-FathomAccess {
    <#
    .SYNOPSIS
        Whether a user with these PSU roles reaches an access tier.
    .EXAMPLE
        if (Test-FathomAccess -Tier Operator -Role $Roles) { Get-FathomDenial }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Reader', 'Operator', 'Admin')]
        [string] $Tier,

        # The user's roles: $Roles inside a PSU app.
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]] $Role
    )

    $allowed = Get-FathomRole -Tier $Tier
    [bool] @($Role | Where-Object { $_ -in $allowed }).Count
}
