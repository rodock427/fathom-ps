# Slow servers, polling intervals and importing an existing log. Needs a throwaway Postgres
# (FATHOM_TEST_DSN) and a Unix shell for the fake lmutil.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester shares BeforeAll variables with It blocks.')]
param()

BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../Modules/Fathom/Fathom.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSql.ps1')
    $fakeLmutil = Join-Path -Path $PSScriptRoot -ChildPath 'fakes/lmutil'
    $env:FAKE_LMUTIL_DIR = $TestDrive
    Copy-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath 'fixtures/lmstat_sample.txt') -Destination "$TestDrive/up.txt"
    Copy-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath 'fixtures/lmstat_sample.txt') -Destination "$TestDrive/partial.txt"
}

Describe 'Polling a slow server' -Skip:(-not $env:FATHOM_TEST_DSN -or $IsWindows) {
    BeforeAll {
        Connect-FathomDatabase -Dsn $env:FATHOM_TEST_DSN
        Initialize-FathomSchema
    }

    AfterAll {
        Disconnect-FathomDatabase
        $env:FAKE_LMUTIL_DIR = $null
    }

    BeforeEach {
        $null = Invoke-SqlUpdate -Query 'TRUNCATE live_status, feature_inventory, monitored_servers, usage_samples, live_sessions, poll_history'
    }

    It 'uses the server''s own time limit, and keeps nothing from a poll cut off part way' {
        $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@partial
        $null = Set-FathomServer -ServerId licsrv01 -PollTimeoutSeconds 5

        $result = Get-FathomServer | Sync-FathomLiveStatus -LmutilPath $fakeLmutil

        $result.Status | Should -Be 'Timeout'
        $result.Message | Should -BeLike '*5 seconds*'
        $result.Features | Should -Be 0
        (Invoke-SqlQuery -Query 'SELECT COUNT(*) AS n FROM usage_samples').n | Should -Be 0
    }

    It 'skips a server that is already being polled' {
        $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@up
        $null = Invoke-SqlQuery -Query "SELECT pg_advisory_lock(hashtext('fathom-poll'), hashtext('licsrv01'))"
        try {
            (Get-FathomServer | Sync-FathomLiveStatus -LmutilPath $fakeLmutil).Status | Should -Be 'Skipped'
            (Get-FathomServer -ServerId licsrv01).LastPolled | Should -BeNullOrEmpty
        } finally {
            $null = Invoke-SqlQuery -Query "SELECT pg_advisory_unlock(hashtext('fathom-poll'), hashtext('licsrv01'))"
        }
        (Get-FathomServer | Sync-FathomLiveStatus -LmutilPath $fakeLmutil).Status | Should -Be 'Up' -Because 'the lock is released afterwards'
    }

    It 'polls a server only when its interval has passed, and allows for that in its health' {
        $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@up
        $null = Set-FathomServer -ServerId licsrv01 -PollMinutes 60
        (Get-FathomServer -Due).ServerId | Should -Be 'licsrv01' -Because 'it has never been polled'

        $null = Get-FathomServer | Sync-FathomLiveStatus -LmutilPath $fakeLmutil
        Get-FathomServer -Due | Should -BeNullOrEmpty

        $null = Invoke-SqlUpdate -Query "UPDATE monitored_servers SET last_polled_at = last_polled_at - interval '30 minutes'"
        Get-FathomServer -Due | Should -BeNullOrEmpty
        (Get-FathomServerHealth -ServerId licsrv01).Status | Should -Not -Be 'Stale'

        $null = Invoke-SqlUpdate -Query "UPDATE monitored_servers SET last_polled_at = last_polled_at - interval '30 minutes'"
        (Get-FathomServer -Due).ServerId | Should -Be 'licsrv01'
    }
}

Describe 'Import-FathomDebugLog' -Skip:(-not $env:FATHOM_TEST_DSN) {
    BeforeAll {
        Connect-FathomDatabase -Dsn $env:FATHOM_TEST_DSN
        Initialize-FathomSchema

        # Starts between date markers, with two seats out when the vendor daemon restarts.
        $log = Join-Path -Path $TestDrive -ChildPath 'copy.log'
        @(
            ' 7:00:00 (mlm) OUT: "CAD" ann@ws1'
            ' 8:00:00 (mlm) TIMESTAMP 3/2/2026'
            ' 8:10:00 (mlm) OUT: "CAD" bob@ws2'
            ' 9:00:00 (lmgrd) Started mlm (pid 41)'
            ' 9:30:00 (mlm) OUT: "CAD" eve@ws3'
        ) | Set-Content -LiteralPath $log
        $from = [datetime] '2026-03-02'
        $to = [datetime] '2026-03-03'
    }

    AfterAll {
        Disconnect-FathomDatabase
    }

    BeforeEach {
        $null = Invoke-SqlUpdate -Query 'TRUNCATE monitored_servers, license_events, log_coverage, _ingest_manifest, usage_samples, live_status'
        $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@up
    }

    It 'adds history without making the file the server''s live log' {
        $null = Import-FathomDebugLog -ServerId licsrv01 -Path $log
        $null = Invoke-SqlUpdate -Query "UPDATE monitored_servers SET last_polled_at = @now::timestamp, last_poll_status = 'Up'" -Parameters @{ now = (Get-Date).ToString('s') }

        (Get-FathomServer -ServerId licsrv01).LogPath | Should -BeNullOrEmpty
        $health = Get-FathomServerHealth -ServerId licsrv01
        $health.EffectiveSource | Should -Be 'auto'
        $health.Status | Should -Not -Be 'Stale'
    }

    It 'dates lines before the first date marker from that marker, not today' {
        $null = Import-FathomDebugLog -ServerId licsrv01 -Path $log

        (Invoke-SqlQuery -Query "SELECT MIN(timestamp) AS first FROM license_events WHERE event_type = 'checkout'").first |
            Should -Be ([datetime] '2026-03-02 07:00:00')
    }

    It 'adds nothing the second time' {
        $null = Import-FathomDebugLog -ServerId licsrv01 -Path $log
        $null = Import-FathomDebugLog -ServerId licsrv01 -Path $log

        (Invoke-SqlQuery -Query "SELECT COUNT(*) AS n FROM license_events WHERE event_type = 'checkout'").n | Should -Be 3
    }

    It 'starts the seat count again at a restart, without changing what is stored' {
        $null = Import-FathomDebugLog -ServerId licsrv01 -Path $log

        $history = Get-FathomUsageHistory -ServerId licsrv01 -From $from -To $to -IntervalMinutes 60 -Source Log
        ($history | Where-Object { $_.BucketStart.Hour -eq 8 }).PeakInUse | Should -Be 2
        ($history | Where-Object { $_.BucketStart.Hour -eq 9 }).PeakInUse | Should -Be 2 -Because 'the seats were out until the restart'
        ($history | Where-Object { $_.BucketStart.Hour -eq 10 }).PeakInUse | Should -Be 1 -Because 'only the checkout after the restart still holds a seat'
        (Invoke-SqlQuery -Query "SELECT COUNT(*) AS n FROM license_events WHERE event_type = 'checkin'").n | Should -Be 0
    }

    It 'refuses a file it can''t find, or an unknown server' {
        { Import-FathomDebugLog -ServerId licsrv01 -Path "$TestDrive/missing.log" } | Should -Throw '*find or read*'
        { Import-FathomDebugLog -ServerId nobody -Path $log } | Should -Throw "*isn't registered*"
    }
}
