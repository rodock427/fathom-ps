# Needs a throwaway Postgres (FATHOM_TEST_DSN) and a Unix shell for the fake lmutil.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester shares BeforeAll variables with It blocks.')]
param()

BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../Modules/Fathom/Fathom.psd1') -Force
    $fakeLmutil = Join-Path -Path $PSScriptRoot -ChildPath 'fakes/lmutil'

    # The fake answers per host from $TestDrive/<host>.txt, and fails for unknown hosts.
    $env:FAKE_LMUTIL_DIR = $TestDrive
    $fixtures = Join-Path -Path $PSScriptRoot -ChildPath 'fixtures'
    Copy-Item -Path "$fixtures/lmstat_sample.txt" -Destination "$TestDrive/up.txt"
    Copy-Item -Path "$fixtures/lmstat_detail.txt" -Destination "$TestDrive/detail.txt"
    "Users of MATLAB:  (Total of 10 licenses issued;  Total of 0 licenses in use)`n  `"MATLAB`" v1, vendor: mlm,`n  licsrv: license server UP" |
        Set-Content -Path "$TestDrive/noexpiry.txt"

    function Get-Row([string] $Query) {
        Invoke-SqlQuery -ConnectionName Fathom -Query $Query -WarningAction SilentlyContinue
    }
}

Describe 'Sync-FathomLiveStatus' -Skip:(-not $env:FATHOM_TEST_DSN -or $IsWindows) {
    BeforeAll {
        Connect-FathomDatabase -Dsn $env:FATHOM_TEST_DSN
        Initialize-FathomSchema
    }

    AfterAll {
        Disconnect-FathomDatabase
        $env:FAKE_LMUTIL_DIR = $null
    }

    BeforeEach {
        $null = Invoke-SqlUpdate -ConnectionName Fathom -Query 'TRUNCATE live_status, feature_inventory, monitored_servers, usage_samples, live_sessions, vendor_daemon_status, observed_sessions, poll_history'
    }

    It 'records live usage and seat limits for a server that is up' {
        $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@up

        $result = Get-FathomServer | Sync-FathomLiveStatus -LmutilPath $fakeLmutil

        $result.Status | Should -Be 'Up'
        $result.Features | Should -Be 3
        (Get-FathomServer -ServerId licsrv01).PollStatus | Should -Be 'Up'
        $matlab = Get-Row "SELECT * FROM live_status WHERE feature = 'MATLAB'"
        $matlab.licenses_issued | Should -Be 10
        $matlab.licenses_in_use | Should -Be 3
        $matlab.vendor_daemon | Should -Be 'mlm'
        (Get-Row "SELECT licenses_issued FROM feature_inventory WHERE feature = 'SIMULINK'").licenses_issued | Should -Be 5
    }

    It 'refreshes seats without touching cost, token family or version' {
        $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@up
        $seed = @'
INSERT INTO feature_inventory (server_id, feature, vendor_daemon, version, licenses_issued, expiration, cost, token_family, updated_at)
VALUES ('licsrv01', 'MATLAB', 'mlm', 'v2025.0100', 4, '2027-01-31', 1200, 'flex', now())
'@
        $null = Invoke-SqlUpdate -ConnectionName Fathom -Query $seed

        $null = Get-FathomServer | Sync-FathomLiveStatus -LmutilPath $fakeLmutil

        $row = Get-Row "SELECT * FROM feature_inventory WHERE feature = 'MATLAB'"
        $row.licenses_issued | Should -Be 10
        $row.cost | Should -Be 1200
        $row.token_family | Should -Be 'flex'
        $row.version | Should -Be 'v2025.0100'
    }

    It 'takes expiry from lmstat when it reports one, and keeps it when it does not' {
        $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@detail
        $seed = @'
INSERT INTO feature_inventory (server_id, feature, licenses_issued, expiration)
VALUES ('licsrv01', 'INVENTOR_PRO', 2, '2026-12-31'), ('licsrv01', 'MATLAB', 10, '2027-06-30')
'@
        $null = Invoke-SqlUpdate -ConnectionName Fathom -Query $seed

        $null = Get-FathomServer | Sync-FathomLiveStatus -LmutilPath $fakeLmutil
        $null = Set-FathomServer -ServerId licsrv01 -LicenseSpec 27000@noexpiry
        $null = Get-FathomServer | Sync-FathomLiveStatus -LmutilPath $fakeLmutil

        $expiry = @{}
        Get-Row 'SELECT feature, expiration FROM feature_inventory' | ForEach-Object { $expiry[$_.feature] = $_.expiration }
        $expiry['87545ACD_2026_0F'] | Should -Be ([datetime] '2027-03-31')
        $expiry['INVENTOR_PRO'] | Should -BeOfType [DBNull] -Because 'lmstat now says permanent'
        $expiry['MATLAB'] | Should -Be ([datetime] '2027-06-30') -Because 'lmstat said nothing about it'
    }

    It 'stores current holders, replacing the previous poll''s' {
        $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@detail
        $null = Get-FathomServer | Sync-FathomLiveStatus -LmutilPath $fakeLmutil
        $null = Set-FathomServer -ServerId licsrv01 -LicenseSpec 27000@up
        $result = Get-FathomServer | Sync-FathomLiveStatus -LmutilPath $fakeLmutil

        $result.Holders | Should -Be 5
        (Get-Row 'SELECT "user" FROM live_sessions ORDER BY "user"').user | Should -Be @('blossom', 'blossom', 'bubbles', 'buttercup', 'jbravo')
    }

    It 'keeps every snapshot as usage history' {
        $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@up
        $null = Get-FathomServer | Sync-FathomLiveStatus -LmutilPath $fakeLmutil
        Start-Sleep -Seconds 1  # samples are keyed by the second
        $null = Get-FathomServer | Sync-FathomLiveStatus -LmutilPath $fakeLmutil

        Invoke-SqlScalar -ConnectionName Fathom -Query 'SELECT count(*) FROM usage_samples' | Should -Be 6
    }

    It 'keeps one row per session across polls, and every poll in the history' {
        $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@detail
        $null = Get-FathomServer | Sync-FathomLiveStatus -LmutilPath $fakeLmutil
        Start-Sleep -Seconds 1
        $null = Get-FathomServer | Sync-FathomLiveStatus -LmutilPath $fakeLmutil

        $sessions = Get-Row 'SELECT * FROM observed_sessions'
        $sessions | Should -HaveCount 5
        $sessions | ForEach-Object { $_.last_seen_at | Should -BeGreaterThan $_.first_seen_at }
        (Get-Row 'SELECT status FROM poll_history').status | Should -Be @('Degraded', 'Degraded')
    }

    It 'calls a server degraded when a vendor daemon is down' {
        $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@detail

        $result = Get-FathomServer | Sync-FathomLiveStatus -LmutilPath $fakeLmutil

        $result.Status | Should -Be 'Degraded'
        $result.Message | Should -BeLike 'mlm: The desired vendor daemon is down*'
        $daemons = Get-Row 'SELECT daemon, up FROM vendor_daemon_status ORDER BY daemon'
        $daemons.daemon | Should -Be @('adskflex', 'mlm')
        $daemons.up | Should -Be @($true, $false)
    }

    It 'marks an unreachable server down, with lmutil''s reason' {
        $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@down

        $result = Get-FathomServer | Sync-FathomLiveStatus -LmutilPath $fakeLmutil

        $result.Status | Should -Be 'Down'
        $result.Message | Should -BeLike '*Cannot connect to license server system*'
        (Get-FathomServer -ServerId licsrv01).PollMessage | Should -Be $result.Message
        Get-Row 'SELECT * FROM live_status' | Should -BeNullOrEmpty
        Get-Row 'SELECT * FROM live_sessions' | Should -BeNullOrEmpty
    }

    It 'gives up on a server that never answers, and polls the rest' {
        $null = Register-FathomServer -ServerId a-hangs -LicenseSpec 27000@hang
        $null = Register-FathomServer -ServerId b-up -LicenseSpec 27000@up

        $elapsed = Measure-Command {
            $script:results = Get-FathomServer | Sync-FathomLiveStatus -LmutilPath $fakeLmutil -TimeoutSeconds 2
        }

        $results.Status | Should -Be @('Timeout', 'Up')
        $elapsed.TotalSeconds | Should -BeLessThan 15
    }

    It 'skips servers monitored by log only' {
        $null = Register-FathomServer -ServerId licsrv01 -LogPath '/nowhere/debug.log'

        Get-FathomServer | Sync-FathomLiveStatus -LmutilPath $fakeLmutil | Should -BeNullOrEmpty
    }

    It 'fails up front when lmutil is missing' {
        $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@up

        { Get-FathomServer | Sync-FathomLiveStatus -LmutilPath '/nowhere/lmutil' } | Should -Throw
    }
}
