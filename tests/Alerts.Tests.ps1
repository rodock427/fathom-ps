# Needs a throwaway Postgres: set FATHOM_TEST_DSN. Mail goes to a pickup folder, never out.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester shares BeforeAll variables with It blocks.')]
param()

BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../Modules/Fathom/Fathom.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSql.ps1')

    function Invoke-Sql([string] $Query, [hashtable] $Parameters = @{}) {
        $null = Invoke-SqlUpdate -Query $Query -Parameters $Parameters
    }

    # Polls every 5 minutes for the last $Minutes, ending with $Status ("Up" before that).
    # Called twice within one second, the later call's polls win.
    function Write-TestOutage([string] $ServerId, [string] $Status, [int] $Minutes, [string] $Message = 'Cannot connect') {
        $now = Get-Date
        $insert = 'INSERT INTO poll_history VALUES (@id, @at::timestamp, @status) ON CONFLICT (server_id, polled_at) DO UPDATE SET status = EXCLUDED.status'
        Invoke-Sql $insert @{ status = 'Up'; id = $ServerId; at = $now.AddMinutes(-$Minutes - 5).ToString('s') }
        for ($m = $Minutes; $m -ge 0; $m -= 5) {
            Invoke-Sql $insert @{ id = $ServerId; at = $now.AddMinutes(-$m).ToString('s'); status = $Status }
        }
        Invoke-Sql 'UPDATE monitored_servers SET last_polled_at = @at::timestamp, last_poll_status = @status, last_poll_message = @message WHERE server_id = @id' @{
            id = $ServerId; at = $now.ToString('s'); status = $Status; message = $Message
        }
    }

    # One string per message sent, oldest first. Wrap calls in @() to index them. The body is
    # quoted-printable, which wraps long lines with "=" + newline; joining them back is enough for ASCII.
    function Get-SentMail {
        Get-ChildItem -Path $mailbox -Filter '*.eml' -ErrorAction Ignore | Sort-Object LastWriteTime |
            ForEach-Object { (Get-Content -Raw -LiteralPath $_.FullName) -replace '=\r?\n', '' }
    }
}

Describe 'Alerts' -Skip:(-not $env:FATHOM_TEST_DSN) {
    BeforeAll {
        Connect-FathomDatabase -Dsn $env:FATHOM_TEST_DSN
        Initialize-FathomSchema
    }

    AfterAll {
        Disconnect-FathomDatabase
    }

    BeforeEach {
        Invoke-Sql 'TRUNCATE monitored_servers, poll_history, live_status, usage_samples, feature_inventory, license_events, log_coverage, alert_state, vendor_daemon_status'
        Invoke-Sql 'DELETE FROM alert_settings; INSERT INTO alert_settings (id) VALUES (1)'
        $mailbox = Join-Path -Path $TestDrive -ChildPath "mail-$([guid]::NewGuid())"
        $null = New-Item -ItemType Directory -Path $mailbox
        $null = Set-FathomAlertSetting -PickupDirectory $mailbox -From fathom@corp.example -To licensing@corp.example, it@corp.example
        $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@licsrv01
    }

    Context 'Sending' {
        It 'records alerts but sends nothing while disabled (the default)' {
            Write-TestOutage -ServerId licsrv01 -Status Down -Minutes 20

            $run = Send-FathomAlert

            $run.New | Should -Be 1
            $run.Sent | Should -BeFalse
            Get-SentMail | Should -BeNullOrEmpty
            Invoke-SqlScalar -Query 'SELECT count(*) FROM alert_state WHERE last_notified_at IS NULL' | Should -Be 1
        }

        It 'mails a new alert once, to every recipient' {
            $null = Set-FathomAlertSetting -Enabled $true
            Write-TestOutage -ServerId licsrv01 -Status Down -Minutes 20

            $first = Send-FathomAlert
            $second = Send-FathomAlert

            $first.Sent | Should -BeTrue
            $second.Sent | Should -BeFalse
            $mail = @(Get-SentMail)
            $mail | Should -HaveCount 1
            $mail[0] | Should -Match 'Subject: \[Critical\] Fathom alerts: 1 new'
            $mail[0] | Should -Match 'To: licensing@corp.example, it@corp.example'
            $mail[0] | Should -Match 'licsrv01 is not answering lmstat: Cannot connect'
            # The outage's own start (the first failed poll), not when Fathom first noticed it.
            $state = Invoke-SqlQuery -Query 'SELECT condition_since, first_seen_at FROM alert_state' -WarningAction SilentlyContinue
            ($state.first_seen_at - $state.condition_since).TotalMinutes | Should -BeGreaterOrEqual 19
            $mail[0] | Should -Match "since $($state.condition_since.ToString('yyyy-MM-dd HH:mm'))"
        }

        It 'mails alerts raised while disabled once enabled, but not ones that came and went unseen' {
            Write-TestOutage -ServerId licsrv01 -Status Down -Minutes 20
            $null = Register-FathomServer -ServerId licsrv02 -LicenseSpec 27000@licsrv02
            Write-TestOutage -ServerId licsrv02 -Status Down -Minutes 20
            $null = Send-FathomAlert
            Write-TestOutage -ServerId licsrv02 -Status Up -Minutes 0
            $null = Send-FathomAlert

            $null = Set-FathomAlertSetting -Enabled $true
            $run = Send-FathomAlert

            $run.New | Should -Be 1
            $run.Resolved | Should -Be 0
            @(Get-SentMail)[0] | Should -Not -Match 'licsrv02'
        }

        It 'mails the resolution of an alert that was mailed' {
            $null = Set-FathomAlertSetting -Enabled $true
            Write-TestOutage -ServerId licsrv01 -Status Down -Minutes 20
            $null = Send-FathomAlert
            Write-TestOutage -ServerId licsrv01 -Status Up -Minutes 0

            $run = Send-FathomAlert

            $run.Resolved | Should -Be 1
            @(Get-SentMail)[-1] | Should -Match 'Subject: Fathom alerts: 1 resolved'
            (Send-FathomAlert).Sent | Should -BeFalse -Because 'a resolution is mailed once'
        }

        It 'reminds about an alert still active after RepeatHours' {
            $null = Set-FathomAlertSetting -Enabled $true -RepeatHours 24
            Write-TestOutage -ServerId licsrv01 -Status Down -Minutes 20
            $null = Send-FathomAlert
            Invoke-Sql "UPDATE alert_state SET last_notified_at = last_notified_at - interval '25 hours'"

            $run = Send-FathomAlert

            $run.Reminders | Should -Be 1
            @(Get-SentMail)[-1] | Should -Match 'STILL ACTIVE'
        }

        It 'treats an alert that returns after clearing as new' {
            $null = Set-FathomAlertSetting -Enabled $true
            Write-TestOutage -ServerId licsrv01 -Status Down -Minutes 20
            $null = Send-FathomAlert
            Write-TestOutage -ServerId licsrv01 -Status Up -Minutes 0
            $null = Send-FathomAlert
            Write-TestOutage -ServerId licsrv01 -Status Down -Minutes 20

            (Send-FathomAlert).New | Should -Be 1
        }

        It 'leaves alerts unsent when sending fails, so the next run retries' {
            Write-TestOutage -ServerId licsrv01 -Status Down -Minutes 20
            $null = Set-FathomAlertSetting -Enabled $true -PickupDirectory '' -SmtpServer ''

            { Send-FathomAlert } | Should -Throw '*needs an SMTP server*'
            Invoke-SqlScalar -Query 'SELECT count(*) FROM alert_state WHERE last_notified_at IS NULL' | Should -Be 1
        }

        It 'sends a test message even while disabled' {
            Send-FathomAlert -Test

            @(Get-SentMail)[0] | Should -Match 'Subject: Fathom: test message'
        }
    }

    Context 'Rules' {
        It 'waits DownMinutes before reporting a server down' {
            Write-TestOutage -ServerId licsrv01 -Status Down -Minutes 5

            Get-FathomAlert | Should -BeNullOrEmpty
        }

        It 'reports a down vendor daemon as a warning' {
            Write-TestOutage -ServerId licsrv01 -Status Degraded -Minutes 20 -Message 'mlm: The desired vendor daemon is down.'

            $alert = Get-FathomAlert
            $alert.Rule | Should -Be 'DaemonDown'
            $alert.Severity | Should -Be 'Warning'
        }

        It 'reports a feature fully used for CapacityMinutes, not a brief spike' {
            $now = Get-Date
            Write-TestOutage -ServerId licsrv01 -Status Up -Minutes 0
            Invoke-Sql "INSERT INTO live_status VALUES ('licsrv01', 'MATLAB', 10, 10, 'mlm', @at::timestamp), ('licsrv01', 'SPIKE', 5, 5, 'mlm', @at::timestamp)" @{ at = $now.ToString('s') }
            foreach ($m in 45, 30, 15, 0) {
                $at = $now.AddMinutes(-$m).ToString('s')
                Invoke-Sql "INSERT INTO usage_samples VALUES ('licsrv01', 'MATLAB', @at::timestamp, 10, 10), ('licsrv01', 'SPIKE', @at::timestamp, 5, @spike)" @{ at = $at; spike = if ($m -le 15) { 5 } else { 2 } }
            }

            $alerts = Get-FathomAlert
            $alerts.Rule | Should -Be 'AtCapacity'
            $alerts.Feature | Should -Be 'MATLAB'
        }

        It 'raises expiry alerts with rising severity' {
            Write-TestOutage -ServerId licsrv01 -Status Up -Minutes 0
            $today = (Get-Date).Date
            Invoke-Sql @'
INSERT INTO feature_inventory (server_id, feature, licenses_issued, expiration) VALUES
('licsrv01', 'SOON', 5, @soon::date), ('licsrv01', 'VERYSOON', 5, @verysoon::date), ('licsrv01', 'GONE', 5, @gone::date)
'@ @{ soon = $today.AddDays(20).ToString('yyyy-MM-dd'); verysoon = $today.AddDays(3).ToString('yyyy-MM-dd'); gone = $today.AddDays(-1).ToString('yyyy-MM-dd') }

            $severity = @{}
            Get-FathomAlert | ForEach-Object { $severity[$_.Feature] = $_.Severity }
            $severity['SOON'] | Should -Be 'Info'
            $severity['VERYSOON'] | Should -Be 'Warning'
            $severity['GONE'] | Should -Be 'Critical'
        }

        It 'reports a drifted log even on a degraded server' {
            $log = Join-Path -Path $TestDrive -ChildPath 'drift.log'
            # Recent, so the log isn't also stale: drift alone is under test.
            $at = (Get-Date).AddMinutes(-10)
            $date = $at.ToString('M/d/yyyy', [cultureinfo]::InvariantCulture)
            "$($at.ToString('HH:mm:ss')) (mlm) TIMESTAMP $date`n$($at.AddMinutes(1).ToString('HH:mm:ss')) (mlm) OUT: `"MATLAB`" alice@ws01`n" |
                Set-Content -Path $log -NoNewline
            $null = Set-FathomServer -ServerId licsrv01 -LogPath $log
            $null = Get-FathomServer | Sync-FathomDebugLog
            Write-TestOutage -ServerId licsrv01 -Status Degraded -Minutes 20 -Message 'mlm: down'
            Invoke-Sql "INSERT INTO live_status VALUES ('licsrv01', 'MATLAB', 10, 6, 'mlm', (SELECT last_polled_at FROM monitored_servers))"

            (Get-FathomAlert).Rule | Sort-Object | Should -Be @('DaemonDown', 'LogDrifted')
        }

        It 'reports stale data' {
            # Local clock, as Fathom stores it; the database's now() may be in another time zone.
            Invoke-Sql "UPDATE monitored_servers SET last_polled_at = @at::timestamp, last_poll_status = 'Up'" @{ at = (Get-Date).AddHours(-2).ToString('s') }

            $alert = Get-FathomAlert
            $alert.Rule | Should -Be 'Stale'
            $alert.Message | Should -BeLike '*no lmstat poll since*'
        }
    }

    Context 'Settings' {
        It 'refuses an invalid address' {
            { Set-FathomAlertSetting -To 'not an address' } | Should -Throw "*isn't a valid email address*"
        }

        It 'starts disabled with sensible thresholds' {
            Invoke-Sql 'DELETE FROM alert_settings; INSERT INTO alert_settings (id) VALUES (1)'
            $settings = Get-FathomAlertSetting

            $settings.Enabled | Should -BeFalse
            $settings.DownMinutes | Should -Be 10
            $settings.ExpiryDays | Should -Be 30
        }
    }
}
