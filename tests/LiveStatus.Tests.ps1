# Needs a throwaway Postgres (FATHOM_TEST_DSN) and a Unix shell for the fake lmutil.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester shares BeforeAll variables with It blocks.')]
param()

BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../Modules/Fathom/Fathom.psd1') -Force
    $fakeLmutil = Join-Path -Path $PSScriptRoot -ChildPath 'fakes/lmutil'

    # The fake answers for host "up" with Fathom's lmstat sample, and fails for unknown hosts.
    $env:FAKE_LMUTIL_DIR = $TestDrive
    Copy-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath 'fixtures/lmstat_sample.txt') -Destination (Join-Path -Path $TestDrive -ChildPath 'up.txt')

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
        $null = Invoke-SqlUpdate -ConnectionName Fathom -Query 'TRUNCATE live_status, feature_inventory, monitored_servers'
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

    It 'refreshes seats without touching cost, version or expiration' {
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
        $row.expiration | Should -Be ([datetime] '2027-01-31')
    }

    It 'marks an unreachable server down, with lmutil''s reason' {
        $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@down

        $result = Get-FathomServer | Sync-FathomLiveStatus -LmutilPath $fakeLmutil

        $result.Status | Should -Be 'Down'
        $result.Message | Should -BeLike '*Cannot connect to license server system*'
        (Get-FathomServer -ServerId licsrv01).PollMessage | Should -Be $result.Message
        Get-Row 'SELECT * FROM live_status' | Should -BeNullOrEmpty
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
