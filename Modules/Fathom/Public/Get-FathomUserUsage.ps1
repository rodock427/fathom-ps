function Get-FathomUserUsage {
    <#
    .SYNOPSIS
        One person's sessions (seen by lmstat) and log events (checkouts, returns, denials), under
        every username they've been seen with. Operator tier.
    .EXAMPLE
        Get-FathomUserUsage -User alice -From (Get-Date).AddDays(-30)
    #>
    [CmdletBinding()]
    [OutputType('Fathom.UserUsage')]
    param(
        # The FlexLM username, as it appears in lmstat and the debug logs.
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string] $User,

        [datetime] $From = (Get-Date).AddDays(-30),

        [datetime] $To = (Get-Date)
    )

    process {
        # Every username this person has been seen with: an old and a new one count as one person.
        $person = Get-FathomPerson -User $User
        $parameters = @{
            names = [string[]] $person.Usernames
            from  = $From | ConvertTo-FathomSqlTime
            to    = $To | ConvertTo-FathomSqlTime
        }

        $sessionQuery = @'
SELECT "user", server_id, feature, host, licenses, started_at, last_seen_at
FROM observed_sessions
WHERE lower("user") = ANY(@names) AND first_seen_at < @to::timestamp AND last_seen_at >= @from::timestamp
ORDER BY started_at DESC
'@
        $sessions = foreach ($row in Invoke-FathomQuery -Query $sessionQuery -Parameters $parameters) {
            [pscustomobject] @{
                Username  = $row.user
                ServerId  = $row.server_id
                Feature   = $row.feature
                Host      = $row.host
                Licenses  = $row.licenses
                StartedAt = $row.started_at
                # Seen to within one poll: the session ended after this, before the next poll.
                LastSeen  = $row.last_seen_at
                Hours     = [Math]::Round(($row.last_seen_at - $row.started_at).TotalHours, 1)
            }
        }

        $eventQuery = @'
SELECT timestamp, "user", server_id, feature, event_type, host, unit_count
FROM license_events
WHERE lower("user") = ANY(@names) AND event_type IN ('checkout', 'checkin', 'denied', 'queued')
  AND timestamp >= @from::timestamp AND timestamp < @to::timestamp
ORDER BY timestamp DESC
'@
        $events = foreach ($row in Invoke-FathomQuery -Query $eventQuery -Parameters $parameters) {
            [pscustomobject] @{
                Time     = $row.timestamp
                Username = $row.user
                ServerId = $row.server_id
                Feature  = $row.feature
                Event    = $row.event_type
                Host     = $row.host
                Licenses = $row.unit_count
            }
        }

        [pscustomobject] @{
            PSTypeName = 'Fathom.UserUsage'
            User       = $User
            Person     = $person.Person
            Usernames  = $person.Usernames
            Sessions   = @($sessions)
            Events     = @($events)
        }
    }
}
