# One user's licensing, or (with nobody picked) who holds a seat right now. Operators only.
. "$PSScriptRoot/../Common.ps1"

if (-not (Test-FathomAccess -Tier Operator -Role $Roles)) {
    return New-FathomNotAuthorized
}

$user = $Query.user
$presets = 7, 30, 90, 365
$timeframe = Get-FathomTimeframe -Query $Query -Presets $presets -DefaultDays 90

Use-FathomDatabase {
    New-UDStack -Direction row -Spacing 2 -AlignItems center -Children {
        New-UDTypography -Variant h4 -Text 'People'
        New-UDElement -Tag div -Attributes @{ style = @{ width = '360px' } } -Content {
            New-UDAutocomplete -Id 'people-search' -Label 'Find a user (name or username)' -FullWidth -OnLoadOptions {
                if (-not (Test-FathomAccess -Tier Operator -Role $Roles)) { return '[]' }
                $found = Use-FathomDatabase { Find-FathomUser -Text ([string] $Body) }
                ConvertTo-Json -Depth 3 -InputObject @(
                    foreach ($match in $found) {
                        $name = if ($match.DisplayName) { "$($match.DisplayName) ($($match.User))" } else { $match.User }
                        New-UDAutoCompleteOption -Name $name -Value $match.User
                    }
                )
            } -OnChange {
                if ($Body) {
                    Invoke-UDRedirect -Url "people?user=$([uri]::EscapeDataString([string] $Body))"
                }
            }
        }
    }

    if (-not $user) {
        New-UDCard -Title 'Holding a seat now' -Content {
            $rows = Get-FathomLicenseHolder | Sort-Object Hours -Descending | ForEach-Object {
                [pscustomobject] @{
                    User    = $_.User
                    Feature = $_.Feature
                    Host    = $_.Host
                    Since   = Format-FathomTime $_.StartedAt
                    Hours   = $_.Hours
                    Long    = $_.Long
                    Server  = $_.ServerId
                }
            }
            $columns = [ordered] @{ User = 'User'; Feature = 'Feature'; Since = 'Since'; Hours = 'Hours'; Host = 'Host'; Server = 'Server' }
            $rows = Add-FathomDirectoryColumn -Rows $rows -Columns $columns
            $table = @{
                Id      = 'people-holders'
                Data    = $rows
                Columns = $columns
                Render  = @{
                    User  = { New-UDLink -Text $EventData.UserLabel -Url "people?user=$([uri]::EscapeDataString($EventData.User))" }
                    Hours = { New-UDChip -Label ([string] $EventData.Hours) -Color ($EventData.Long ? 'warning' : 'default') -Size small }
                }
                Empty   = 'Nobody holds a seat right now.'
            }
            New-FathomTable @table
        }
        return
    }

    # One person: who they are, then what they used under any of their usernames, in tabs.
    $directory = Get-FathomDirectoryObject -Kind user -Name $user
    $usage = Get-FathomUserUsage -User $user -From $timeframe.From -To $timeframe.To
    $several = $usage.Usernames.Count -gt 1
    New-UDCard -Id 'people-profile' -Content {
        $title = if ($directory.Attributes.DisplayName) { "$($directory.Attributes.DisplayName) ($user)" } else { $user }
        New-UDStack -Direction row -Spacing 2 -AlignItems center -Children {
            New-UDTypography -Variant h5 -Text $title
            New-UDLink -Text 'Back to everyone' -Url 'people'
        }
        # The usernames this person has been seen with (an old and a new one, say).
        $others = @($usage.Usernames | Where-Object { $_ -ne $user.ToLowerInvariant() })
        if ($others) {
            New-UDTypography -Id 'people-usernames' -Variant body2 -Text "Also seen as: $($others -join ', ')"
        }
        if ($directory.Found -and $directory.Attributes.Count) {
            New-UDGrid -Id 'people-directory' -Container -Spacing 1 -Children {
                foreach ($name in $directory.Attributes.Keys | Where-Object { $_ -ne 'DisplayName' }) {
                    New-UDGrid -Item -ExtraSmallSize 12 -SmallSize 6 -MediumSize 4 -Children {
                        New-UDTypography -Variant caption -Text $name
                        New-UDTypography -Variant body2 -Text (Format-FathomDirectoryValue $directory.Attributes[$name])
                    }
                }
            }
        } elseif ($directory -and -not $directory.Found) {
            New-UDTypography -Id 'people-directory' -Variant body2 -Text 'Not found in Active Directory.'
        }
    }

    New-FathomTimeframePicker -Timeframe $timeframe -Presets $presets -Page 'people' -Keep @{ user = $user }

    New-UDTabs -Id 'people-tabs' -Tabs {
        New-UDTab -Text "Sessions ($(@($usage.Sessions).Count))" -Content {
            $sessions = $usage.Sessions | ForEach-Object {
                [pscustomobject] @{
                    Username = $_.Username
                    Server   = $_.ServerId
                    Feature  = $_.Feature
                    Host     = $_.Host
                    Started  = Format-FathomTime $_.StartedAt
                    LastSeen = Format-FathomTime $_.LastSeen
                    Hours    = $_.Hours
                }
            }
            $table = @{
                Id      = 'people-sessions'
                Data    = $sessions
                Columns = [ordered] @{ Feature = 'Feature'; Started = 'Started'; LastSeen = 'Last seen'; Hours = 'Hours'; Host = 'Host'; Server = 'Server' }
                Empty   = 'No sessions seen by lmstat in this period.'
            }
            if ($several) {
                $table.Columns.Insert(0, 'Username', 'Username')
            }
            New-FathomTable @table
        }

        New-UDTab -Text "Log events ($(@($usage.Events).Count))" -Content {
            $events = $usage.Events | ForEach-Object {
                [pscustomobject] @{ Time = Format-FathomTime $_.Time; Username = $_.Username; Event = $_.Event; Feature = $_.Feature; Host = $_.Host; Server = $_.ServerId }
            }
            $table = @{
                Id      = 'people-events'
                Data    = $events
                Columns = [ordered] @{ Time = 'Time'; Event = 'Event'; Feature = 'Feature'; Host = 'Host'; Server = 'Server' }
                Empty   = 'No debug log events in this period.'
            }
            if ($several) {
                $table.Columns.Insert(1, 'Username', 'Username')
            }
            New-FathomTable @table
        }

        New-UDTab -Text 'Directory changes' -Content {
            $changes = Get-FathomDirectoryHistory -Kind user -Name $user | Sort-Object Time -Descending | ForEach-Object {
                [pscustomobject] @{
                    Time      = Format-FathomTime $_.Time
                    Attribute = $_.Attribute
                    From      = if ($null -eq $_.From) { '(first recorded)' } else { Format-FathomDirectoryValue $_.From }
                    To        = Format-FathomDirectoryValue $_.To
                }
            }
            $table = @{
                Id      = 'people-directory-changes'
                Data    = $changes
                Columns = [ordered] @{ Time = 'When'; Attribute = 'Attribute'; From = 'From'; To = 'To' }
                Empty   = 'No Active Directory values recorded for this user.'
            }
            New-FathomTable @table
        }
    }
}
