# Needs a throwaway Postgres (FATHOM_TEST_DSN). Active Directory is tests/fakes/ActiveDirectory.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester shares BeforeAll variables with It blocks.')]
param()

BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../Modules/Fathom/Fathom.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSql.ps1')
}

Describe 'Directory values' {
    It 'keeps text, numbers and true/false as they are' {
        InModuleScope Fathom {
            ConvertTo-FathomDirectoryValue -Value 'Engineering' | Should -Be 'Engineering'
            ConvertTo-FathomDirectoryValue -Value 42L | Should -Be 42
            ConvertTo-FathomDirectoryValue -Value $true | Should -BeTrue
        }
    }

    It 'turns dates, GUIDs and enums into text' {
        InModuleScope Fathom {
            ConvertTo-FathomDirectoryValue -Value ([datetime] '2021-03-15 09:30') | Should -Be '2021-03-15T09:30:00'
            ConvertTo-FathomDirectoryValue -Value ([guid] '11111111-2222-4333-8444-555555555555') | Should -Be '11111111-2222-4333-8444-555555555555'
            ConvertTo-FathomDirectoryValue -Value ([DayOfWeek]::Monday) | Should -Be 'Monday'
        }
    }

    It 'keeps a one-item list a list, and drops binary values' {
        InModuleScope Fathom {
            , (ConvertTo-FathomDirectoryValue -Value ([string[]] @('CN=One'))) | Should -BeOfType [object[]]
            ConvertTo-FathomDirectoryValue -Value ([byte[]] (1..4)) | Should -BeNullOrEmpty
        }
    }

    It 'keys hosts without their domain, and everything in lower case' {
        InModuleScope Fathom {
            'WS-02.corp.local' | Get-FathomDirectoryKey -Kind computer | Should -Be 'ws-02'
            'Dave' | Get-FathomDirectoryKey -Kind user | Should -Be 'dave'
        }
    }
}

Describe 'Sync-FathomDirectory' -Skip:(-not $env:FATHOM_TEST_DSN) {
    BeforeAll {
        $env:PSModulePath = (Join-Path -Path $PSScriptRoot -ChildPath 'fakes') + [IO.Path]::PathSeparator + $env:PSModulePath
        Import-Module ActiveDirectory -Force
        Connect-FathomDatabase -Dsn $env:FATHOM_TEST_DSN
        Initialize-FathomSchema

        function Get-Stored([string] $Kind, [string] $Name) {
            $row = Invoke-SqlQuery -Query 'SELECT attributes::text AS a FROM ad_objects WHERE kind = @kind AND name = @name' -Parameters @{ kind = $Kind; name = $Name } -WarningAction SilentlyContinue
            $row.a | ConvertFrom-Json -AsHashtable
        }
    }

    AfterAll {
        Disconnect-FathomDatabase
        Remove-Module ActiveDirectory -ErrorAction Ignore
    }

    BeforeEach {
        $null = Invoke-SqlUpdate -Query 'TRUNCATE ad_objects, ad_attributes, ad_history, live_sessions, observed_sessions, license_events'
        $null = Invoke-SqlUpdate -Query 'UPDATE ad_settings SET enabled = TRUE, server = NULL, refresh_hours = 24'
        $seed = @'
INSERT INTO live_sessions (server_id, feature, "user", host, captured_at) VALUES
('licsrv01', 'MATLAB', 'Dave', 'WS-04.corp.local', now()),
('licsrv01', 'MATLAB', 'ghost', 'kiosk', now())
'@
        $null = Invoke-SqlUpdate -Query $seed
    }

    It 'looks up nothing while lookups are off' {
        $null = Set-FathomDirectorySetting -Enabled $false

        (Sync-FathomDirectory).Looked | Should -Be 0
        Get-FathomDirectoryAttribute | Should -BeNullOrEmpty
    }

    It 'looks up each seen user and host once, noting the ones the directory lacks' {
        $result = Sync-FathomDirectory

        $result.Looked | Should -Be 4
        $result.Found | Should -Be 2
        $result.NotFound | Should -Be 2
        (Sync-FathomDirectory).Looked | Should -Be 0 -Because 'nothing is due again for RefreshHours'
    }

    It 'catalogs every attribute but records only the default few' {
        $null = Sync-FathomDirectory
        $catalog = Get-FathomDirectoryAttribute -Kind user

        $catalog.Name | Should -Contain 'MemberOf'
        $catalog.Name | Should -Contain 'SID'
        $catalog.Name | Should -Not -Contain 'thumbnailPhoto' -Because 'binary values are never recorded'
        ($catalog | Where-Object Recorded).Name | Sort-Object | Should -Be @('Department', 'DisplayName', 'EmailAddress', 'Manager', 'Office', 'Title')
        $stored = Get-Stored -Kind user -Name dave
        $stored.Department | Should -Be 'Manufacturing'
        $stored.Keys | Should -Not -Contain 'telephoneNumber'
        (Get-Stored -Kind computer -Name ws-04).OperatingSystem | Should -Be 'Windows 11 Enterprise'
    }

    It 'records an attribute once chosen, in a form JSON holds' {
        $null = Sync-FathomDirectory
        foreach ($name in 'MemberOf', 'SID', 'whenCreated') {
            $null = Set-FathomDirectoryAttribute -Kind user -Name $name -Recorded $true
        }
        # Newly recorded attributes make every user due again, without waiting RefreshHours.
        (Sync-FathomDirectory).Looked | Should -Be 2

        $stored = Get-Stored -Kind user -Name dave
        $stored.MemberOf | Should -HaveCount 2
        $stored.SID | Should -BeLike 'S-1-5-21-*'
        $stored.whenCreated | Should -Be ([datetime] '2021-03-15 09:30')
    }

    It 'deletes stored values at once when an attribute stops being recorded' {
        $null = Sync-FathomDirectory
        $attribute = Set-FathomDirectoryAttribute -Kind user -Name Department -Recorded $false

        $attribute.Shown | Should -BeFalse
        (Get-Stored -Kind user -Name dave).Keys | Should -Not -Contain 'Department'
        (Get-Stored -Kind user -Name dave).Keys | Should -Contain 'Title'
    }

    It 'lists Department by default, and cascades the three switches' {
        $null = Sync-FathomDirectory
        (Get-FathomDirectoryAttribute -Kind user | Where-Object Listed).Name | Should -Be 'Department'

        $title = Set-FathomDirectoryAttribute -Kind user -Name Company -Listed $true
        $title.Shown | Should -BeTrue -Because 'listing shows'
        $title.Recorded | Should -BeTrue -Because 'showing records'

        (Set-FathomDirectoryAttribute -Kind user -Name Company -Shown $false).Listed | Should -BeFalse -Because 'hiding unlists'
        $null = Set-FathomDirectoryAttribute -Kind user -Name Company -Listed $true
        $off = Set-FathomDirectoryAttribute -Kind user -Name Company -Recorded $false
        $off.Shown | Should -BeFalse
        $off.Listed | Should -BeFalse
    }

    It 'records an attribute that is shown' {
        $null = Sync-FathomDirectory
        $attribute = Set-FathomDirectoryAttribute -Kind user -Name Company -Shown $true

        $attribute.Recorded | Should -BeTrue
    }

    It 'returns only shown attributes, or every recorded one with -All' {
        $null = Sync-FathomDirectory
        $null = Set-FathomDirectoryAttribute -Kind user -Name Office -Shown $false

        $dave = Get-FathomDirectoryObject -Kind user -Name 'DAVE'
        $dave.Attributes.Keys | Should -Not -Contain 'Office'
        $dave.Attributes.DisplayName | Should -Be 'Dave Diaz'
        (Get-FathomDirectoryObject -Kind user -Name dave -All).Attributes.Office | Should -Be 'Plant 3'
        (Get-FathomDirectoryObject -Kind computer -Name 'WS-04.corp.local').Attributes.OperatingSystem | Should -Be 'Windows 11 Enterprise'
        (Get-FathomDirectoryObject -Kind user -Name ghost).Found | Should -BeFalse
    }

    It 'returns a name the directory lacks when no attribute is known yet' {
        $null = Invoke-SqlUpdate -Query 'DELETE FROM live_sessions WHERE "user" = ''Dave'''
        (Sync-FathomDirectory).Found | Should -Be 0

        $object = Get-FathomDirectoryObject -Kind user -Name ghost
        $object.Found | Should -BeFalse
        $object.Attributes.Count | Should -Be 0
    }

    It 'keeps a history of changes, without repeating unchanged values' {
        $null = Sync-FathomDirectory
        $null = Invoke-SqlUpdate -Query "UPDATE ad_objects SET fetched_at = '-infinity'"
        $null = Sync-FathomDirectory
        @(Get-FathomDirectoryHistory -Kind user -Name dave | Where-Object Attribute -EQ 'Department').Count | Should -Be 1 -Because 'nothing changed on the second lookup'

        # A day later (history is kept to the second), dave moves department in AD.
        $null = Invoke-SqlUpdate -Query "UPDATE ad_history SET changed_at = changed_at - interval '1 day'"

        Mock -CommandName Get-ADUser -ModuleName Fathom -MockWith {
            $users = if ($Filter) { ActiveDirectory\Get-ADUser -Filter $Filter } else { ActiveDirectory\Get-ADUser -Identity $Identity }
            foreach ($user in $users) {
                if ($user.SamAccountName -eq 'dave') { $user.Department = 'Quality' }
                $user
            }
        }
        $null = Invoke-SqlUpdate -Query "UPDATE ad_objects SET fetched_at = '-infinity'"
        $null = Sync-FathomDirectory
        $changes = @(Get-FathomDirectoryHistory -Kind user -Name dave | Where-Object Attribute -EQ 'Department')
        $changes.Count | Should -Be 2
        $changes[-1].From | Should -Be 'Manufacturing'
        $changes[-1].To | Should -Be 'Quality'
    }

    It 'removes an unrecorded attribute from the history too' {
        $null = Sync-FathomDirectory
        $null = Set-FathomDirectoryAttribute -Kind user -Name Department -Recorded $false

        $stored = Invoke-SqlQuery -Query "SELECT count(*) AS n FROM ad_history WHERE attributes ? 'Department'" -WarningAction SilentlyContinue
        $stored.n | Should -Be 0
    }

    It 'finds users by username, or by display name when it''s shown' {
        $null = Sync-FathomDirectory
        (Find-FathomUser -Text 'DAV').User | Should -Contain 'Dave'
        (Find-FathomUser -Text 'Diaz').User | Should -Contain 'Dave'
        $null = Set-FathomDirectoryAttribute -Kind user -Name DisplayName -Shown $false
        (Find-FathomUser -Text 'Diaz') | Should -BeNullOrEmpty -Because 'a hidden display name is not searched'
    }

    It 'matches a username to either logon name: pre-Windows 2000 or userPrincipalName' {
        $seed = @'
INSERT INTO live_sessions (server_id, feature, "user", host, captured_at) VALUES
('licsrv01', 'MATLAB', 'alice.archer', 'WS-01', now()),
('licsrv01', 'MATLAB', 'carol.chen@corp.local', 'WS-03', now()),
('licsrv01', 'MATLAB', 'johnny.bravo', 'WS-10', now())
'@
        $null = Invoke-SqlUpdate -Query $seed
        $null = Sync-FathomDirectory

        (Get-FathomDirectoryObject -Kind user -Name 'Dave').Attributes.DisplayName | Should -Be 'Dave Diaz' -Because 'pre-Windows 2000 name'
        (Get-FathomDirectoryObject -Kind user -Name 'alice.archer').Attributes.DisplayName | Should -Be 'Alice Archer' -Because 'the user logon name, without its domain'
        (Get-FathomDirectoryObject -Kind user -Name 'carol.chen@corp.local').Attributes.DisplayName | Should -Be 'Carol Chen' -Because 'the full user logon name'
        (Get-FathomDirectoryObject -Kind user -Name 'johnny.bravo').Found | Should -BeFalse -Because 'two people share that name in different domains'
    }

    It 'treats two usernames for the same account as one person' {
        $seed = @'
INSERT INTO live_sessions (server_id, feature, "user", host, captured_at) VALUES
('licsrv01', 'MATLAB', 'alice', 'WS-01', now()),
('licsrv01', 'SIMULINK', 'alice.archer', 'WS-01', now());
INSERT INTO observed_sessions (server_id, feature, "user", host, handle, started_at, licenses, first_seen_at, last_seen_at) VALUES
('licsrv01', 'MATLAB', 'alice', 'WS-01', '1', @now::timestamp - interval '2 hours', 1, @now::timestamp - interval '2 hours', @now::timestamp),
('licsrv01', 'SIMULINK', 'alice.archer', 'WS-01', '2', @now::timestamp - interval '1 hour', 1, @now::timestamp - interval '1 hour', @now::timestamp)
'@
        # Local time, as Fathom stores it (the database's now() may be in another zone).
        $null = Invoke-SqlUpdate -Query $seed -Parameters @{ now = (Get-Date).ToString('s') }
        $null = Sync-FathomDirectory

        (Get-FathomPerson -User 'alice.archer').Usernames | Should -Be @('alice', 'alice.archer')
        (Get-FathomPerson -User 'ALICE').Person | Should -Be 'alice.archer@corp.local'
        $usage = Get-FathomUserUsage -User 'alice' -From (Get-Date).AddDays(-1)
        @($usage.Sessions).Count | Should -Be 2 -Because 'both usernames are hers'
        @(Find-FathomUser -Text 'alice').Count | Should -Be 1
        $people = Invoke-SqlQuery -Query "SELECT count(DISTINCT fathom_person(u)) AS n FROM unnest(ARRAY['alice', 'alice.archer', 'ALICE', 'Dave']) u" -WarningAction SilentlyContinue
        $people.n | Should -Be 2 -Because 'alice three ways is one person; Dave is another'
    }

    It 'stops the run when the directory itself fails' {
        Mock -CommandName Get-ADUser -ModuleName Fathom -MockWith { throw [System.TimeoutException]::new('The server is not operational') }

        { Sync-FathomDirectory } | Should -Throw '*not operational*'
    }
}
