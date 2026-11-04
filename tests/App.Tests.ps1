# Renders every app page as each tier and checks what reaches the browser. Needs PSU's Universal
# module (for the UD cmdlets), a throwaway Postgres (FATHOM_TEST_DSN) and a Unix shell for the
# fake lmutil.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester shares BeforeAll variables with It blocks.')]
param()

BeforeDiscovery {
    $canRender = $env:FATHOM_TEST_DSN -and -not $IsWindows -and (Get-Module -ListAvailable -Name Universal)
}

BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../Modules/Fathom/Fathom.psd1') -Force
    $PSDefaultParameterValues['*-Sql*:ConnectionName'] = InModuleScope Fathom { $script:ConnectionName }
    $pages = Join-Path -Path $PSScriptRoot -ChildPath '../Apps/Fathom/Pages'

    # A page renders as PSU would run it: $Roles and $Query set, the components as output.
    function Invoke-TestPage([string] $Page, [string[]] $Role, [hashtable] $Query = @{}) {
        $Roles = $Role
        . (Join-Path -Path $pages -ChildPath "$Page.ps1")
    }

    # Every component and table row in a rendered page. Event handlers are skipped: PSU sends
    # them to the browser as ids only.
    function Get-TestNode($Node) {
        if ($Node -is [string] -or $null -eq $Node) {
            return
        }
        if ($Node -is [System.Collections.IDictionary]) {
            $Node
            foreach ($value in $Node.Values) { Get-TestNode $value }
        } elseif ($Node.PSObject.BaseObject -is [System.Management.Automation.PSCustomObject]) {
            $Node
            foreach ($property in $Node.PSObject.Properties) { Get-TestNode $property.Value }
        } elseif ($Node.GetType().FullName -eq 'UniversalDashboard.Models.Basics.Element') {
            # New-UDElement returns a .NET object; its rendered children are in Content.
            Get-TestNode $Node.Content
        } elseif ($Node -is [System.Collections.IEnumerable]) {
            foreach ($item in $Node) { Get-TestNode $item }
        }
    }

    # Every string a page sends: text, labels, links and table cells.
    function Get-TestText($Node) {
        foreach ($item in Get-TestNode $Node) {
            $values = if ($item -is [System.Collections.IDictionary]) { $item.Values } else { $item.PSObject.Properties.Value }
            $values | Where-Object { $_ -is [string] }
        }
    }

    function Get-TestId($Node) {
        Get-TestNode $Node | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.id -is [string] } |
            ForEach-Object { $_.id }
    }
}

Describe 'Access tiers' {
    It 'includes every tier below and PSU''s Administrator' {
        Get-FathomRole -Tier Reader | Should -Be @('FathomReader', 'FathomOperator', 'FathomAdmin', 'Administrator')
        Get-FathomRole -Tier Admin | Should -Be @('FathomAdmin', 'Administrator')
    }

    It 'grants a tier only to roles that reach it' {
        Test-FathomAccess -Tier Operator -Role 'FathomReader' | Should -BeFalse
        Test-FathomAccess -Tier Operator -Role 'Reader', 'FathomOperator' | Should -BeTrue
        Test-FathomAccess -Tier Admin -Role 'Administrator' | Should -BeTrue
        Test-FathomAccess -Tier Reader -Role 'Reader', 'Operator' | Should -BeFalse
        Test-FathomAccess -Tier Reader -Role $null | Should -BeFalse
    }
}

Describe 'Status colours' {
    BeforeAll {
        . (Join-Path -Path $PSScriptRoot -ChildPath '../Apps/Fathom/Common.ps1')
    }

    It 'colours <Status> as <Color>' -ForEach @(
        @{ Status = 'Healthy'; Color = 'success' }
        @{ Status = 'Up'; Color = 'success' }
        @{ Status = 'Degraded'; Color = 'warning' }
        @{ Status = 'Stale'; Color = 'warning' }
        @{ Status = 'Drifted'; Color = 'warning' }
        @{ Status = 'Down'; Color = 'error' }
        @{ Status = 'Timeout'; Color = 'error' }
        @{ Status = 'Disabled'; Color = 'default' }
        @{ Status = 'Unknown'; Color = 'default' }
    ) {
        Get-FathomStatusColor $Status | Should -Be $Color
    }
}

Describe 'App pages' -Skip:(-not $canRender) {
    BeforeAll {
        Import-Module Universal
        Connect-FathomDatabase -Dsn $env:FATHOM_TEST_DSN
        Initialize-FathomSchema
        $null = Invoke-SqlUpdate -Query 'TRUNCATE license_events, live_status, feature_inventory, _ingest_manifest, monitored_servers, usage_samples, live_sessions, vendor_daemon_status, observed_sessions, poll_history, log_coverage, alert_state'

        # lmstat holders (alice, bob, carol, dave and more) and a debug log an hour old with a denial.
        $env:FAKE_LMUTIL_DIR = $TestDrive
        Copy-Item -Path "$PSScriptRoot/fixtures/lmstat_detail.txt" -Destination "$TestDrive/detail.txt"
        $at = (Get-Date).AddHours(-1)
        $time = { param($minutes) $at.AddMinutes($minutes).ToString('HH:mm:ss') }
        @(
            "$(& $time 0) (mlm) TIMESTAMP $($at.ToString('M/d/yyyy', [cultureinfo]::InvariantCulture))"
            "$(& $time 1) (mlm) OUT: `"MATLAB`" starfire@ws01"
            "$(& $time 2) (mlm) DENIED: `"MATLAB`" raven@ws02 (Licensed number of users already reached. (-4,342))"
        ) | Set-Content -Path "$TestDrive/debug.log"

        $null = Register-FathomServer -ServerId licsrv01 -Name 'Engineering' -LicenseSpec 27000@detail -LogPath "$TestDrive/debug.log"
        $null = Get-FathomServer | Sync-FathomLiveStatus -LmutilPath (Join-Path -Path $PSScriptRoot -ChildPath 'fakes/lmutil')
        $null = Get-FathomServer | Sync-FathomDebugLog

        # Active Directory from the fake: the default attributes recorded and shown.
        $env:PSModulePath = (Join-Path -Path $PSScriptRoot -ChildPath 'fakes') + [IO.Path]::PathSeparator + $env:PSModulePath
        Import-Module ActiveDirectory -Force
        $null = Invoke-SqlUpdate -Query 'TRUNCATE ad_objects, ad_attributes'
        $null = Set-FathomDirectorySetting -Enabled $true
        $null = Sync-FathomDirectory

        # Usernames, and the names Active Directory gives them.
        $users = 'alice', 'bob', 'carol', 'dave', 'starfire', 'raven', 'Dave Diaz', 'Alice Archer'
        $reader = @('FathomReader')
        $operator = @('FathomOperator')
        $admin = @('FathomAdmin')
    }

    AfterAll {
        $null = Set-FathomDirectorySetting -Enabled $false
        Disconnect-FathomDatabase
        $env:FAKE_LMUTIL_DIR = $null
        Remove-Module ActiveDirectory -ErrorAction Ignore
    }

    It 'renders <Page> as <Tier> without an error component' -ForEach @(
        @{ Page = 'Overview'; Tier = 'FathomReader' }
        @{ Page = 'Overview'; Tier = 'FathomOperator' }
        @{ Page = 'Server'; Tier = 'FathomOperator' }
        @{ Page = 'Capacity'; Tier = 'FathomOperator' }
        @{ Page = 'People'; Tier = 'FathomOperator' }
        @{ Page = 'Admin'; Tier = 'FathomAdmin' }
    ) {
        $nodes = Get-TestNode (Invoke-TestPage -Page $Page -Role $Tier -Query @{ days = '1'; user = 'dave' })
        $errors = $nodes | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.type -eq 'error' }
        $errors.errorRecords.message | Should -BeNullOrEmpty
    }

    It 'shows a reader totals and no individual on <Page>' -ForEach @(
        @{ Page = 'Overview' }
        @{ Page = 'Server'; Query = @{ days = '1' } }
    ) {
        $output = Invoke-TestPage -Page $Page -Role $reader -Query ($Query ?? @{})
        $text = Get-TestText $output

        foreach ($user in $users) {
            $text | Where-Object { $_ -match "\b$([regex]::Escape($user))\b" } | Should -BeNullOrEmpty -Because "$user is individual data"
        }
        Get-TestId $output | Should -Not -Contain 'overview-denials'
        Get-TestId $output | Should -Not -Contain 'server-holders'
    }

    It 'shows an operator who holds and who was denied' {
        Get-TestId (Invoke-TestPage -Page Overview -Role $operator) | Should -Contain 'overview-denials'
        $server = Invoke-TestPage -Page Server -Role $operator -Query @{ days = '1' }
        Get-TestId $server | Should -Contain 'server-holders'
        Get-TestId $server | Should -Contain 'server-denials'
        $text = Get-TestText $server
        $text | Should -Contain 'dave'
        $text | Should -Contain 'raven'
    }

    It 'turns away a reader from the <Page> page entirely' -ForEach @(
        @{ Page = 'Capacity' }
        @{ Page = 'People' }
        @{ Page = 'Admin' }
    ) {
        $output = Invoke-TestPage -Page $Page -Role $reader -Query @{ user = 'dave' }
        Get-TestId $output | Should -Be 'not-authorized'
    }

    It 'turns away an operator from the admin page' {
        Get-TestId (Invoke-TestPage -Page Admin -Role $operator) | Should -Be 'not-authorized'
    }

    It 'turns away a user with no Fathom role, even with PSU console roles' {
        Get-TestId (Invoke-TestPage -Page Overview -Role 'Reader', 'Operator') | Should -Be 'not-authorized'
    }

    It 'gives operators the capacity report and a user''s history' {
        Get-TestId (Invoke-TestPage -Page Capacity -Role $operator) | Should -Contain 'capacity-report'
        $people = Invoke-TestPage -Page People -Role $operator -Query @{ user = 'dave' }
        Get-TestId $people | Should -Contain 'people-sessions'
        Get-TestId $people | Should -Contain 'people-holders'
    }

    It 'shows operators what Active Directory says, as chosen on the admin page' {
        $people = Invoke-TestPage -Page People -Role $operator -Query @{ user = 'dave' }
        $text = Get-TestText $people

        Get-TestId $people | Should -Contain 'people-directory'
        $text | Should -Contain 'Dave Diaz'
        $text | Should -Contain 'Manufacturing'
        $text | Should -Contain 'Morgan Manager' -Because 'a distinguished name shows as its name'
        $text | Should -Contain 'Department' -Because 'shown attributes become holder columns'
        $text | Should -Contain 'Host OperatingSystem'
    }

    It 'gives admins the server list and settings' {
        $ids = Get-TestId (Invoke-TestPage -Page Admin -Role $admin)
        $ids | Should -Contain 'admin-servers'
        $ids | Should -Contain 'admin-alerts'
        (Get-TestText (Invoke-TestPage -Page Admin -Role $admin)) | Should -Contain 'Engineering'
    }

    It 'charts only the busiest features of a server with many, and lists them all' {
        $null = Register-FathomServer -ServerId wide -Name 'Wide' -LicenseSpec 27000@wide
        # 30 features, FEATURE_30 busiest: in use rises with the feature number, 10 seats each.
        $seed = @'
INSERT INTO usage_samples (server_id, feature, captured_at, licenses_issued, licenses_in_use)
SELECT 'wide', 'FEATURE_' || lpad(f::text, 2, '0'), @now::timestamp - make_interval(mins => 5 * s), 10, f / 3
FROM generate_series(1, 30) f, generate_series(1, 12) s
'@
        $null = Invoke-SqlUpdate -Query $seed -Parameters @{ now = (Get-Date).ToString('s') }
        function Get-Chart($Output) { Get-TestNode $Output | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.type -eq 'ud-chartjs' } }

        $page = Invoke-TestPage -Page Server -Role $reader -Query @{ id = 'wide'; days = '1' }
        $charts = @(Get-Chart $page)
        $charts.Count | Should -Be 8
        $charts.id | Should -Contain 'server-usage-FEATURE_30'
        $charts.id | Should -Not -Contain 'server-usage-FEATURE_01'
        $table = Get-TestNode $page | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.id -eq 'server-features' }
        @($table.data).Count | Should -Be 30

        $one = Invoke-TestPage -Page Server -Role $reader -Query @{ id = 'wide'; days = '1'; feature = 'FEATURE_01' }
        (@(Get-Chart $one)).id | Should -Be 'server-usage-FEATURE_01'
    }

    It 'falls back to 7 days for a range that is not offered' {
        $buttons = Get-TestNode (Invoke-TestPage -Page Server -Role $reader -Query @{ days = '100000' }) |
            Where-Object { $_ -is [System.Collections.IDictionary] -and $_.type -eq 'mu-button' -and $_.variant -eq 'contained' }
        $buttons.text | Should -Contain '7 days'
        $buttons.text | Should -Not -Contain '100000 days'
    }
}
