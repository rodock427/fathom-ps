# Needs a throwaway Postgres: set FATHOM_TEST_DSN. Never point it at a real database.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester shares BeforeAll variables with It blocks.')]
param()

BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../Modules/Fathom/Fathom.psd1') -Force
    # The module names its connection per import; send the tests' own SQL calls there too.
    $PSDefaultParameterValues['*-Sql*:ConnectionName'] = InModuleScope Fathom { $script:ConnectionName }
    $golden = Get-Content -Raw -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'fixtures/metrics.golden.json') |
        ConvertFrom-Json -AsHashtable

    function Invoke-Sql([string] $Query, [hashtable] $Parameters = @{}) {
        $null = Invoke-SqlUpdate -Query $Query -Parameters $Parameters
    }

    # A server as the lmstat poll leaves it: latest poll at $PolledAt, features in live_status.
    function Write-TestPoll([string] $ServerId, [datetime] $PolledAt, [string] $Status = 'Up', [object[]] $Feature = @()) {
        Invoke-Sql 'UPDATE monitored_servers SET last_polled_at = @at::timestamp, last_poll_status = @status WHERE server_id = @id' @{
            id = $ServerId; at = $PolledAt.ToString('s'); status = $Status
        }
        foreach ($f in $Feature) {
            Invoke-Sql @'
INSERT INTO live_status (server_id, feature, licenses_issued, licenses_in_use, vendor_daemon, captured_at)
VALUES (@id, @feature, @issued, @in_use, @vendor, @at::timestamp)
ON CONFLICT (server_id, feature) DO UPDATE SET licenses_issued = EXCLUDED.licenses_issued,
    licenses_in_use = EXCLUDED.licenses_in_use, vendor_daemon = EXCLUDED.vendor_daemon, captured_at = EXCLUDED.captured_at
'@ @{ id = $ServerId; feature = $f.Feature; issued = $f.Issued; in_use = $f.InUse; vendor = $f.Vendor ?? 'mlm'; at = ($f.At ?? $PolledAt).ToString('s') }
        }
    }
}

Describe 'Monitoring queries' -Skip:(-not $env:FATHOM_TEST_DSN) {
    BeforeAll {
        Connect-FathomDatabase -Dsn $env:FATHOM_TEST_DSN
        Initialize-FathomSchema
    }

    AfterAll {
        Disconnect-FathomDatabase
    }

    BeforeEach {
        Invoke-Sql 'TRUNCATE license_events, _ingest_manifest, monitored_servers, live_status, feature_inventory, usage_samples, live_sessions, vendor_daemon_status, poll_history, observed_sessions, log_coverage'
    }

    Context 'Parity with Python Fathom''s peak_concurrency and denial_rate' {
        BeforeEach {
            $log = Join-Path -Path $TestDrive -ChildPath 'emulator.log'
            Copy-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath 'fixtures/emulator_day.log') -Destination $log
            $null = Register-FathomServer -ServerId parity -LogPath $log
            $null = Get-FathomServer | Sync-FathomDebugLog
        }

        It 'reports the same peak, denials and checkouts for the <_> window' -ForEach 'whole-day', 'afternoon' {
            $window = $golden[$_]
            $report = Get-FathomCapacityReport -ServerId parity -From $window.start -To $window.end

            foreach ($feature in $window.peak.Keys) {
                $row = $report | Where-Object Feature -EQ $feature
                $row.Peak | Should -Be $window.peak[$feature] -Because "$feature peak"
                $row.Denials | Should -Be $window.denials[$feature] -Because "$feature denials"
                $row.Checkouts | Should -Be $window.checkouts[$feature] -Because "$feature checkouts"
            }
        }

        It 'agrees on the peak at any bucket size (<_> minutes)' -ForEach 5, 60, 1440 {
            $window = $golden['afternoon']
            $history = Get-FathomUsageHistory -ServerId parity -Source Log -From $window.start -To $window.end -IntervalMinutes $_

            foreach ($feature in $window.peak.Keys) {
                ($history | Where-Object Feature -EQ $feature | Measure-Object -Property PeakInUse -Maximum).Maximum |
                    Should -Be $window.peak[$feature] -Because "$feature at $_-minute buckets"
            }
        }
    }

    Context 'Get-FathomUsageHistory from lmstat' {
        It 'takes the highest reading per bucket and leaves gaps out' {
            $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@licsrv01
            Invoke-Sql @'
INSERT INTO usage_samples (server_id, feature, captured_at, licenses_issued, licenses_in_use) VALUES
('licsrv01', 'MATLAB', '2026-11-02 09:00', 10, 3), ('licsrv01', 'MATLAB', '2026-11-02 09:05', 10, 7),
('licsrv01', 'MATLAB', '2026-11-02 11:10', 10, 2)
'@
            $history = Get-FathomUsageHistory -ServerId licsrv01 -Source Lmstat -From '2026-11-02 09:00' -To '2026-11-02 12:00' -IntervalMinutes 60

            $history.BucketStart | Should -Be @([datetime] '2026-11-02 09:00', [datetime] '2026-11-02 11:00')
            $history.PeakInUse | Should -Be @(7, 2)
            $history.Issued | Should -Be @(10, 10)
        }
    }

    Context 'Auto source, per bucket' {
        It 'uses the log where it has coverage, lmstat in its gaps, and nothing where neither has data' {
            # Log covers 09:00-10:00 only; lmstat has readings at 09:30 and 11:30; nothing at 12:00-13:00.
            $log = Join-Path -Path $TestDrive -ChildPath 'auto.log'
            @(
                '09:00:00 (lmgrd) FLEXnet Licensing (v11) started on licsrv01 (Windows) (11/2/2026)'
                '09:10:00 (mlm) OUT: "MATLAB" alice@ws01 (3 licenses)'
                '09:59:00 (mlm) IN: "MATLAB" alice@ws01 (3 licenses)'
            ) -join "`n" | Set-Content -Path $log
            $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@licsrv01 -LogPath $log
            $null = Get-FathomServer | Sync-FathomDebugLog
            Invoke-Sql @'
INSERT INTO usage_samples (server_id, feature, captured_at, licenses_issued, licenses_in_use) VALUES
('licsrv01', 'MATLAB', '2026-11-02 09:30', 10, 8), ('licsrv01', 'MATLAB', '2026-11-02 11:30', 10, 6)
'@
            $history = Get-FathomUsageHistory -ServerId licsrv01 -Source Auto -From '2026-11-02 09:00' -To '2026-11-02 13:00' -IntervalMinutes 60

            $history | ForEach-Object { "$($_.BucketStart.Hour):$($_.Source):$($_.PeakInUse)" } |
                Should -Be @('9:log:3', '11:lmstat:6')
        }

        It 'trusts a log ingested before coverage was recorded' {
            $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@licsrv01 -LogPath '/old/debug.log'
            Invoke-Sql @'
INSERT INTO license_events (event_id, event_type, timestamp, server_format, server_id, feature, "user", unit_count, raw_line, source_file, line_number, ingest_batch_id)
VALUES ('o1', 'checkout', '2026-11-02 09:10', 'flexlm', 'licsrv01', 'MATLAB', 'alice', 2, 'x', 'x', 1, 'x')
'@
            $history = Get-FathomUsageHistory -ServerId licsrv01 -Source Auto -From '2026-11-02 09:00' -To '2026-11-02 10:00' -IntervalMinutes 60

            $history.Source | Should -Be 'log'
            $history.PeakInUse | Should -Be 2
        }

        It 'keeps trusting older history once coverage starts being recorded' {
            $log = Join-Path -Path $TestDrive -ChildPath 'later.log'
            "11:00:00 (lmgrd) FLEXnet Licensing (v11) started on licsrv01 (Windows) (11/2/2026)`n11:10:00 (mlm) OUT: `"MATLAB`" bob@ws02" | Set-Content -Path $log
            $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@licsrv01 -LogPath $log
            # An event from before coverage existed, then a covered read starting at 11:00.
            Invoke-Sql @'
INSERT INTO license_events (event_id, event_type, timestamp, server_format, server_id, feature, "user", unit_count, raw_line, source_file, line_number, ingest_batch_id)
VALUES ('o1', 'checkout', '2026-11-02 09:10', 'flexlm', 'licsrv01', 'MATLAB', 'alice', 2, 'x', 'x', 1, 'x')
'@
            $null = Get-FathomServer | Sync-FathomDebugLog

            $history = Get-FathomUsageHistory -ServerId licsrv01 -Source Auto -From '2026-11-02 08:00' -To '2026-11-02 12:00' -IntervalMinutes 60

            $history | ForEach-Object { "$($_.BucketStart.Hour):$($_.Source)" } | Should -Be @('9:log', '10:log', '11:log')
        }
    }

    Context 'Get-FathomAvailability' {
        It 'counts only the latest poll, and no free seats while the vendor daemon is down' {
            $now = Get-Date
            $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@licsrv01
            Write-TestPoll licsrv01 $now -Status Degraded -Feature @(
                @{ Feature = 'MATLAB'; Issued = 10; InUse = 3 }
                @{ Feature = 'ACAD'; Issued = 5; InUse = 1; Vendor = 'adskflex' }
                @{ Feature = 'OLD'; Issued = 5; InUse = 0; At = $now.AddDays(-3) }
            )
            Invoke-Sql "INSERT INTO vendor_daemon_status VALUES ('licsrv01', 'adskflex', FALSE, 'down', now())"

            $available = Get-FathomAvailability

            $available.Feature | Should -Be @('ACAD', 'MATLAB')
            ($available | Where-Object Feature -EQ 'MATLAB').Free | Should -Be 7
            ($available | Where-Object Feature -EQ 'ACAD').Free | Should -Be 0
        }

        It 'shows nothing for a server whose latest poll failed' {
            $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@licsrv01
            Write-TestPoll licsrv01 (Get-Date) -Status Down -Feature @(@{ Feature = 'MATLAB'; Issued = 10; InUse = 3 })

            Get-FathomAvailability | Should -BeNullOrEmpty
        }
    }

    Context 'Get-FathomServerHealth' {
        It 'calls a server <Status> when <Case>' -ForEach @(
            @{ Status = 'Healthy'; Case = 'the poll is fresh'; PollMinutesAgo = 2; PollStatus = 'Up' }
            @{ Status = 'Down'; Case = 'lmstat failed'; PollMinutesAgo = 2; PollStatus = 'Down' }
            @{ Status = 'Degraded'; Case = 'a vendor daemon is down'; PollMinutesAgo = 2; PollStatus = 'Degraded' }
            @{ Status = 'Stale'; Case = 'no poll for an hour'; PollMinutesAgo = 60; PollStatus = 'Up' }
        ) {
            $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@licsrv01
            Write-TestPoll licsrv01 (Get-Date).AddMinutes(-$PollMinutesAgo) -Status $PollStatus

            (Get-FathomServerHealth).Status | Should -Be $Status
        }

        It 'distrusts a log whose seat count drifted from lmstat, and falls back to lmstat' {
            $log = Join-Path -Path $TestDrive -ChildPath 'drift.log'
            "09:00:00 (mlm) TIMESTAMP 11/2/2026`n09:01:00 (mlm) OUT: `"MATLAB`" alice@ws01`n" | Set-Content -Path $log -NoNewline
            $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@licsrv01 -LogPath $log
            $null = Get-FathomServer | Sync-FathomDebugLog

            # The log says 1 seat in use; lmstat says 6.
            Write-TestPoll licsrv01 (Get-Date) -Feature @(@{ Feature = 'MATLAB'; Issued = 10; InUse = 6 })
            $drifted = Get-FathomServerHealth
            Write-TestPoll licsrv01 (Get-Date) -Feature @(@{ Feature = 'MATLAB'; Issued = 10; InUse = 1 })
            $agreeing = Get-FathomServerHealth

            $drifted.Status | Should -Be 'Drifted'
            $drifted.LogDrift | Should -Be 5
            $drifted.EffectiveSource | Should -Be 'lmstat'
            $agreeing.Status | Should -Be 'Healthy'
            $agreeing.EffectiveSource | Should -Be 'auto'
        }

        It 'uses the source a server is forced to' {
            $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@licsrv01 -LogPath '/logs/debug.log'
            $null = Set-FathomServer -ServerId licsrv01 -UsageSource Log

            (Get-FathomServerHealth).EffectiveSource | Should -Be 'log'
        }
    }

    Context 'Get-FathomExpiry' {
        It 'lists what expires within the window, and expired features only on request' {
            $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@licsrv01
            $today = (Get-Date).Date
            Invoke-Sql @'
INSERT INTO feature_inventory (server_id, feature, licenses_issued, expiration) VALUES
('licsrv01', 'SOON', 5, @soon::date), ('licsrv01', 'LATER', 5, @later::date),
('licsrv01', 'GONE', 5, @gone::date), ('licsrv01', 'FOREVER', 5, NULL)
'@ @{ soon = $today.AddDays(10).ToString('yyyy-MM-dd'); later = $today.AddDays(200).ToString('yyyy-MM-dd'); gone = $today.AddDays(-3).ToString('yyyy-MM-dd') }

            (Get-FathomExpiry -WithinDays 30).Feature | Should -Be 'SOON'
            (Get-FathomExpiry -WithinDays 30).DaysLeft | Should -Be 10
            (Get-FathomExpiry -WithinDays 30 -IncludeExpired).Feature | Should -Be @('GONE', 'SOON')
        }
    }

    Context 'Operator queries' {
        BeforeEach {
            $polledAt = [datetime] '2026-11-02 14:30'
            $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@licsrv01
            Write-TestPoll licsrv01 $polledAt -Feature @(@{ Feature = 'MATLAB'; Issued = 10; InUse = 2 })
            Invoke-Sql @'
INSERT INTO live_sessions (server_id, feature, "user", host, licenses, started_at, captured_at) VALUES
('licsrv01', 'MATLAB', 'alice', 'ws01', 1, '2026-11-02 08:30', '2026-11-02 14:30'),
('licsrv01', 'MATLAB', 'carol', 'ws03', 1, '2026-10-30 16:00', '2026-11-02 14:30'),
('licsrv01', 'MATLAB', 'stale', 'ws09', 1, '2026-10-01 09:00', '2026-10-01 10:00');
INSERT INTO observed_sessions (server_id, feature, "user", host, handle, started_at, licenses, first_seen_at, last_seen_at) VALUES
('licsrv01', 'MATLAB', 'alice', 'ws01', '1', '2026-11-01 09:00', 1, '2026-11-01 09:00', '2026-11-01 12:00'),
('licsrv01', 'MATLAB', 'bob', 'ws02', '2', '2026-11-01 10:00', 1, '2026-11-01 10:00', '2026-11-01 10:30');
INSERT INTO usage_samples (server_id, feature, captured_at, licenses_issued, licenses_in_use) VALUES
('licsrv01', 'MATLAB', '2026-11-01 09:00', 10, 2), ('licsrv01', 'MATLAB', '2026-11-01 10:00', 10, 4);
INSERT INTO feature_inventory (server_id, feature, licenses_issued) VALUES ('licsrv01', 'MATLAB', 10);
'@
        }

        It 'lists current holders from the latest poll and flags long sessions' {
            $holders = Get-FathomLicenseHolder

            $holders.User | Should -Be @('carol', 'alice')
            ($holders | Where-Object User -EQ 'carol').Long | Should -BeTrue
            ($holders | Where-Object User -EQ 'alice').Hours | Should -Be 6
        }

        It 'reports an lmstat-only server''s denials as unknown, not zero' {
            $null = Set-FathomServer -ServerId licsrv01 -UsageSource Lmstat
            $row = Get-FathomCapacityReport -From '2026-11-01' -To '2026-11-02'

            $row.Source | Should -Be 'lmstat'
            $row.Peak | Should -Be 4
            $row.Denials | Should -BeNullOrEmpty
            $row.DenialRate | Should -BeNullOrEmpty
            $row.ActiveUsers | Should -Be 2
            $row.Underused | Should -BeTrue -Because 'a peak of 4 is under half of 10 seats'
        }

        It 'finds one user''s sessions and log events' {
            Invoke-Sql @'
INSERT INTO license_events (event_id, event_type, timestamp, server_format, server_id, feature, "user", host, unit_count, raw_line, source_file, line_number, ingest_batch_id)
VALUES ('d1', 'denied', '2026-11-01 11:00', 'flexlm', 'licsrv01', 'MATLAB', 'alice', 'ws01', 1, 'x', 'x', 1, 'x')
'@
            $usage = Get-FathomUserUsage -User alice -From '2026-11-01' -To '2026-11-03'

            $usage.Sessions.Hours | Should -Be 3
            $usage.Events.Event | Should -Be 'denied'
            (Get-FathomDenial -User alice -From '2026-11-01' -To '2026-11-03').Feature | Should -Be 'MATLAB'
        }
    }

    Context 'Get-FathomServerUptime' {
        It 'measures uptime and the longest outage from the poll history' {
            $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@licsrv01
            Invoke-Sql @'
INSERT INTO poll_history (server_id, polled_at, status) VALUES
('licsrv01', '2026-11-02 09:00', 'Up'), ('licsrv01', '2026-11-02 09:05', 'Down'),
('licsrv01', '2026-11-02 09:10', 'Timeout'), ('licsrv01', '2026-11-02 09:15', 'Degraded')
'@
            $uptime = Get-FathomServerUptime -From '2026-11-02' -To '2026-11-03'

            $uptime.UptimePercent | Should -Be 50
            $uptime.Outages | Should -Be 1
            $uptime.LongestOutage | Should -Be ([timespan]::FromMinutes(10))
        }
    }
}
