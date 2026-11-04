function Get-FathomPerson {
    <#
    .SYNOPSIS
        The person behind a FlexLM username, and every username they've been seen with. Operator tier.
    .DESCRIPTION
        Usernames that Active Directory matched to the same account are one person (an old and a new
        username, say). A username AD doesn't know is a person of its own.
    .EXAMPLE
        (Get-FathomPerson -User kory.anders).Usernames    # kory.anders, starfire
    #>
    [CmdletBinding()]
    [OutputType('Fathom.Person')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string] $User
    )

    process {
        $query = @'
SELECT fathom_person(@user) AS person,
       ARRAY(SELECT name FROM ad_objects WHERE kind = 'user' AND person = fathom_person(@user) ORDER BY name) AS usernames
'@
        $row = Invoke-FathomQuery -Query $query -Parameters @{ user = $User }
        $usernames = @(@($row.usernames) + $User.ToLowerInvariant() | Where-Object { $_ } | Sort-Object -Unique)
        [pscustomobject] @{
            PSTypeName = 'Fathom.Person'
            Person     = $row.person
            Usernames  = $usernames
        }
    }
}
