function ConvertTo-FathomAlert {
    <#
    .SYNOPSIS
        Builds one alert object from a rule's findings.
    #>
    [CmdletBinding()]
    [OutputType('Fathom.Alert')]
    param(
        # Stable while the condition lasts, so the alert is mailed once, not every run.
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [string] $Rule,
        [Parameter(Mandatory)] [ValidateSet('Critical', 'Warning', 'Info')] [string] $Severity,
        [Parameter(Mandatory)] [string] $Message,
        [string] $ServerId,
        [string] $Feature,
        [Nullable[datetime]] $Since
    )

    [pscustomobject] @{
        PSTypeName = 'Fathom.Alert'
        Key        = $Key
        Rule       = $Rule
        Severity   = $Severity
        ServerId   = $ServerId
        Feature    = $Feature
        Message    = $Message
        Since      = $Since
    }
}
