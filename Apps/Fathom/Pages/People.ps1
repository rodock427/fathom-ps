# Who holds what right now (long sessions flagged), and one user's last 90 days. Operators only.
. "$PSScriptRoot/../Common.ps1"

if (-not (Test-FathomAccess -Tier Operator -Role $Roles)) {
    return New-FathomNotAuthorized
}

$user = $Query.user

Use-FathomDatabase {
    New-UDTypography -Variant h4 -Text 'People' -GutterBottom

    New-UDForm -Id 'people-lookup' -SubmitText 'Look up' -Children {
        New-UDTextbox -Id 'user' -Label 'FlexLM username' -Value $user
    } -OnSubmit {
        Invoke-UDRedirect -Url "people?user=$([uri]::EscapeDataString($EventData.user))"
    }

    if ($user) {
        $usage = Get-FathomUserUsage -User $user -From (Get-Date).AddDays(-90)
        New-UDCard -Title "$user, last 90 days" -Content {
            # What Active Directory says about them: only the attributes an admin chose to show.
            $directory = Get-FathomDirectoryObject -Kind user -Name $user
            if ($directory.Found -and $directory.Attributes.Count) {
                $details = foreach ($name in $directory.Attributes.Keys) {
                    [pscustomobject] @{ Attribute = $name; Value = Format-FathomDirectoryValue $directory.Attributes[$name] }
                }
                New-FathomTable -Id 'people-directory' -Data $details -Columns ([ordered] @{ Attribute = 'Active Directory'; Value = '' })
            } elseif ($directory -and -not $directory.Found) {
                New-UDTypography -Id 'people-directory' -Variant body2 -Text 'Not found in Active Directory.'
            }

            $sessions = $usage.Sessions | ForEach-Object {
                [pscustomobject] @{
                    Server   = $_.ServerId
                    Feature  = $_.Feature
                    Host     = $_.Host
                    Licenses = $_.Licenses
                    Started  = Format-FathomTime $_.StartedAt
                    LastSeen = Format-FathomTime $_.LastSeen
                    Hours    = $_.Hours
                }
            }
            $table = @{
                Id      = 'people-sessions'
                Data    = $sessions
                Columns = [ordered] @{ Feature = 'Feature'; Started = 'Started'; LastSeen = 'Last seen'; Hours = 'Hours'; Host = 'Host'; Server = 'Server' }
                Empty   = 'No sessions seen by lmstat.'
            }
            New-FathomTable @table

            $events = $usage.Events | ForEach-Object {
                [pscustomobject] @{ Time = Format-FathomTime $_.Time; Event = $_.Event; Feature = $_.Feature; Host = $_.Host; Server = $_.ServerId }
            }
            $table = @{
                Id      = 'people-events'
                Data    = $events
                Columns = [ordered] @{ Time = 'Time'; Event = 'Event'; Feature = 'Feature'; Host = 'Host'; Server = 'Server' }
                Empty   = 'No debug log events.'
            }
            New-FathomTable @table
        }
    }

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
                User  = { New-UDLink -Text $EventData.User -Url "people?user=$([uri]::EscapeDataString($EventData.User))" }
                Hours = { New-UDChip -Label ([string] $EventData.Hours) -Color ($EventData.Long ? 'warning' : 'default') -Size small }
            }
            Empty   = 'Nobody holds a seat right now.'
        }
        New-FathomTable @table
    }
}
