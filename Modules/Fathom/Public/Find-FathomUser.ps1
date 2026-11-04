function Find-FathomUser {
    <#
    .SYNOPSIS
        FlexLM usernames matching some text, or whose shown Active Directory display name does.
        Individual data: Operator tier.
    .EXAMPLE
        Find-FathomUser -Text dav
    #>
    [CmdletBinding()]
    [OutputType('Fathom.UserMatch')]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text,

        [ValidateRange(1, 200)]
        [int] $Limit = 20
    )

    # Display names only when admins show them; the log only for 90 days, to keep typing quick.
    $byDisplayName = [bool] (Get-FathomDirectoryAttribute -Kind user | Where-Object { $_.Name -eq 'DisplayName' -and $_.Shown })
    $query = @'
WITH names AS (
    SELECT "user" AS name FROM live_sessions
    UNION SELECT "user" FROM observed_sessions
    UNION SELECT "user" FROM license_events WHERE "user" <> '' AND timestamp >= @recent::timestamp
)
SELECT n.name, d.attributes->>'DisplayName' AS display_name
FROM names n
LEFT JOIN ad_objects d ON d.kind = 'user' AND d.name = lower(n.name)
WHERE n.name ILIKE @pattern OR (@by_display AND d.attributes->>'DisplayName' ILIKE @pattern)
ORDER BY lower(n.name)
LIMIT @limit
'@
    $parameters = @{
        pattern    = '%' + ($Text -replace '([\\%_])', '\$1') + '%'
        by_display = $byDisplayName
        recent     = (Get-Date).AddDays(-90) | ConvertTo-FathomSqlTime
        limit      = $Limit
    }
    foreach ($row in Invoke-FathomQuery -Query $query -Parameters $parameters) {
        [pscustomobject] @{
            PSTypeName  = 'Fathom.UserMatch'
            User        = $row.name
            DisplayName = if ($byDisplayName) { $row.display_name }
        }
    }
}
