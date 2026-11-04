# Needs a throwaway Postgres: set FATHOM_TEST_DSN. Never point it at a real database.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester shares BeforeAll variables with It blocks.')]
param()

BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../Modules/Fathom/Fathom.psd1') -Force
    $fixture = [System.IO.File]::ReadAllLines((Join-Path -Path $PSScriptRoot -ChildPath 'fixtures/emulator.log'))

    function Write-TestLog([string] $Path, [string[]] $Line, [switch] $Append) {
        $text = ($Line -join "`n") + "`n"
        if ($Append) {
            [System.IO.File]::AppendAllText($Path, $text)
        } else {
            [System.IO.File]::WriteAllText($Path, $text)
        }
    }

    # What a server's stored events look like, minus the per-run ids, for comparing two reads.
    function Get-StoredEvent([string] $ServerId) {
        $query = 'SELECT line_number, event_type, timestamp, raw_line FROM license_events WHERE server_id = @id ORDER BY line_number'
        (Invoke-SqlQuery -ConnectionName Fathom -Query $query -Parameters @{ id = $ServerId } -WarningAction SilentlyContinue) |
            ForEach-Object { '{0}|{1}|{2:s}|{3}' -f $_.line_number, $_.event_type, $_.timestamp, $_.raw_line }
    }

    function Register-TestServer([string] $ServerId) {
        $path = Join-Path -Path $TestDrive -ChildPath "$ServerId.log"
        $null = Register-FathomServer -ServerId $ServerId -LogPath $path
        $path
    }
}

Describe 'Monitored servers and log sync' -Skip:(-not $env:FATHOM_TEST_DSN) {
    BeforeAll {
        Connect-FathomDatabase -Dsn $env:FATHOM_TEST_DSN
        Initialize-FathomSchema
    }

    AfterAll {
        Disconnect-FathomDatabase
    }

    BeforeEach {
        $null = Invoke-SqlUpdate -ConnectionName Fathom -Query 'TRUNCATE license_events, _ingest_manifest, monitored_servers'
    }

    Context 'Register-FathomServer' {
        It 'registers a server and returns it' {
            $server = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@licsrv01 -Vendor mlm

            $server.Name | Should -Be 'licsrv01'
            $server.Enabled | Should -BeTrue
            (Get-FathomServer -ServerId licsrv01).LicenseSpec | Should -Be '27000@licsrv01'
        }

        It 'refuses a duplicate id' {
            $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@licsrv01
            { Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@other } | Should -Throw '*already registered*'
        }

        It 'refuses a server with nothing to monitor' {
            { Register-FathomServer -ServerId licsrv01 } | Should -Throw '*nothing to monitor*'
        }

        It 'refuses an id that is not a slug' {
            { Register-FathomServer -ServerId 'bad id' -LicenseSpec 27000@x } | Should -Throw
        }

        It 'unregisters a server and its read positions, but keeps its history' {
            $path = Register-TestServer a_b
            Write-TestLog $path $fixture
            $null = Get-FathomServer | Sync-FathomDebugLog

            Unregister-FathomServer -ServerId a_b -Confirm:$false

            Get-FathomServer | Should -BeNullOrEmpty
            Invoke-SqlScalar -ConnectionName Fathom -Query 'SELECT count(*) FROM _ingest_manifest' | Should -Be 0
            Invoke-SqlScalar -ConnectionName Fathom -Query 'SELECT count(*) FROM license_events' | Should -BeGreaterThan 0
        }
    }

    Context 'Sync-FathomDebugLog' {
        It 'reads a whole log, then nothing on the next run' {
            $path = Register-TestServer licsrv01
            Write-TestLog $path $fixture

            $first = Get-FathomServer | Sync-FathomDebugLog
            $second = Get-FathomServer | Sync-FathomDebugLog

            $first.Status | Should -Be 'Synced'
            $first.LinesRead | Should -Be $fixture.Count
            $first.EventsWritten | Should -Be 638
            $second.Status | Should -Be 'UpToDate'
            $second.EventsWritten | Should -Be 0
        }

        It 'stamps read positions with the local clock, like event timestamps' {
            $path = Register-TestServer licsrv01
            Write-TestLog $path $fixture[0..9]

            $null = Get-FathomServer | Sync-FathomDebugLog

            $ingestedAt = Invoke-SqlScalar -ConnectionName Fathom -Query 'SELECT last_ingested_at FROM _ingest_manifest'
            [Math]::Abs(((Get-Date) - $ingestedAt).TotalMinutes) | Should -BeLessThan 2
        }

        It 'stores the same events whether a log is read in one go, in small chunks, or as it grows' {
            Write-TestLog (Register-TestServer oneshot) $fixture
            Write-TestLog (Register-TestServer chunked) $fixture
            $growing = Register-TestServer growing
            Write-TestLog $growing $fixture[0..299]

            $null = Get-FathomServer -ServerId oneshot | Sync-FathomDebugLog
            $null = Get-FathomServer -ServerId chunked | Sync-FathomDebugLog -ChunkSize 4KB
            $null = Get-FathomServer -ServerId growing | Sync-FathomDebugLog
            Write-TestLog $growing $fixture[300..($fixture.Count - 1)] -Append
            $null = Get-FathomServer -ServerId growing | Sync-FathomDebugLog

            $expected = Get-StoredEvent oneshot
            $expected.Count | Should -Be 638
            Get-StoredEvent chunked | Should -Be $expected
            Get-StoredEvent growing | Should -Be $expected
        }

        It 'leaves a half-written line for the next run' {
            $path = Register-TestServer licsrv01
            Write-TestLog $path $fixture[0..9]
            [System.IO.File]::AppendAllText($path, '12:00:00 (mlm) OUT: "MAT')

            $null = Get-FathomServer | Sync-FathomDebugLog
            [System.IO.File]::AppendAllText($path, "LAB`" alice@ws01`n")
            $result = Get-FathomServer | Sync-FathomDebugLog

            $result.LinesRead | Should -Be 1
            (Get-StoredEvent licsrv01)[-1] | Should -BeLike '11|checkout|*|12:00:00 (mlm) OUT: "MATLAB" alice@ws01'
        }

        It 'reads a replaced log from the start' {
            $path = Register-TestServer licsrv01
            Write-TestLog $path $fixture
            $null = Get-FathomServer | Sync-FathomDebugLog

            # A restarted lmgrd writes a new banner, so the first line differs.
            Write-TestLog $path (@('09:00:00 (lmgrd) FLEXnet Licensing (v11) started on licsrv01 (Windows) (9/1/2026)') + $fixture[1..20])
            $result = Get-FathomServer | Sync-FathomDebugLog

            $result.LinesRead | Should -Be 21
            $result.EventsWritten | Should -BeGreaterThan 0
        }

        It 'warns and skips a log that shrank but still starts the same' {
            $path = Register-TestServer licsrv01
            Write-TestLog $path $fixture
            $null = Get-FathomServer | Sync-FathomDebugLog

            Write-TestLog $path $fixture[0..5]
            $result = Get-FathomServer | Sync-FathomDebugLog -WarningVariable warnings -WarningAction SilentlyContinue

            $result.Status | Should -Be 'Shrunk'
            $warnings | Should -BeLike '*shrank*'
        }

        It 'waits while the first line is still being written' {
            $path = Register-TestServer licsrv01
            [System.IO.File]::WriteAllText($path, '09:00:00 (lmgrd) FLEXnet Lic')

            (Get-FathomServer | Sync-FathomDebugLog).Status | Should -Be 'WaitingForFirstLine'
        }

        It 'reports an unreachable log without stopping the other servers' {
            $null = Register-FathomServer -ServerId aaa-missing -LogPath (Join-Path -Path $TestDrive -ChildPath 'nope.log')
            Write-TestLog (Register-TestServer zzz-present) $fixture

            $results = Get-FathomServer | Sync-FathomDebugLog -ErrorVariable failures -ErrorAction SilentlyContinue

            $failures | Should -HaveCount 1
            $failures[0].TargetObject | Should -Be 'aaa-missing'
            $results.ServerId | Should -Be 'zzz-present'
        }

        It 'skips servers monitored by lmstat only' {
            $null = Register-FathomServer -ServerId licsrv01 -LicenseSpec 27000@licsrv01

            Get-FathomServer | Sync-FathomDebugLog | Should -BeNullOrEmpty
        }
    }
}
