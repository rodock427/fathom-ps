# Runs every standard report against a throwaway Postgres (FATHOM_TEST_DSN), and opens the files
# they export. Needs ImportExcel for the Excel half.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester shares BeforeAll variables with It blocks.')]
param()

BeforeDiscovery {
    $canRun = [bool] $env:FATHOM_TEST_DSN
    $canExcel = $canRun -and (Get-Module -ListAvailable -Name ImportExcel)
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../Modules/Fathom/Fathom.psd1') -Force
    $names = @((Get-FathomReportCatalog).Name | ForEach-Object { @{ Name = $_ } })
}

BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../Modules/Fathom/Fathom.psd1') -Force
}

Describe 'The report catalog' {
    It 'gives every option a kind the report page can draw' {
        foreach ($spec in (Get-FathomReportCatalog).Options) {
            $spec.Kind | Should -BeIn 'Server', 'Feature', 'Features', 'Number', 'Choice'
        }
    }

    It 'gives a period only to reports with a default' {
        foreach ($report in Get-FathomReportCatalog) {
            [bool] $report.Presets | Should -Be ([bool] $report.DefaultDays)
            if ($report.Presets) { $report.DefaultDays | Should -BeIn $report.Presets }
        }
    }
}

Describe 'Standard reports' -Skip:(-not $canRun) {
    BeforeAll {
        . (Join-Path -Path $PSScriptRoot -ChildPath 'TestSql.ps1')
        Connect-FathomDatabase -Dsn $env:FATHOM_TEST_DSN
        Initialize-FathomSchema
        $null = Invoke-SqlUpdate -Query 'TRUNCATE license_events, live_status, feature_inventory, _ingest_manifest, monitored_servers, usage_samples, live_sessions, vendor_daemon_status, observed_sessions, poll_history, log_coverage, alert_state, ad_objects'

        $env:FAKE_LMUTIL_DIR = $TestDrive
        Copy-Item -Path "$PSScriptRoot/fixtures/lmstat_detail.txt" -Destination "$TestDrive/detail.txt"
        # An hour of log: one person out for 20 minutes, someone with a formula for a name, a denial.
        $at = (Get-Date).AddHours(-1)
        $line = { param($minutes, $rest) '{0} (mlm) {1}' -f $at.AddMinutes($minutes).ToString('HH:mm:ss'), $rest }
        @(
            & $line 0 "TIMESTAMP $($at.ToString('M/d/yyyy', [cultureinfo]::InvariantCulture))"
            & $line 1 'OUT: "MATLAB" starfire@ws01'
            & $line 21 'IN: "MATLAB" starfire@ws01'
            & $line 22 'OUT: "MATLAB" =HYPERLINK("x")@ws02'
            & $line 23 'DENIED: "MATLAB" raven@ws03 (Licensed number of users already reached. (-4,342))'
            & $line 24 'DENIED: "MATLAB" raven@ws03 (Licensed number of users already reached. (-4,342))'
        ) | Set-Content -Path "$TestDrive/debug.log"
        $null = Register-FathomServer -ServerId licsrv01 -Name 'Engineering' -LicenseSpec 27000@detail -LogPath "$TestDrive/debug.log"
        $null = Get-FathomServer | Sync-FathomLiveStatus -LmutilPath (Join-Path -Path $PSScriptRoot -ChildPath 'fakes/lmutil')
        $null = Get-FathomServer | Sync-FathomDebugLog
        $period = @{ From = (Get-Date).AddDays(-1); To = (Get-Date).AddMinutes(1) }
    }

    AfterAll {
        Disconnect-FathomDatabase
        $env:FAKE_LMUTIL_DIR = $null
    }

    It 'runs <Name>, whose columns are all on its rows' -ForEach $names {
        $report = Get-FathomReport -Name $Name @period
        foreach ($row in $report.Rows) {
            foreach ($property in $report.Columns.Keys) {
                $row.PSObject.Properties.Name | Should -Contain $property
            }
        }
    }

    It 'falls back to the default for an option out of range or not a number' {
        (Get-FathomReport -Name top-users -Option @{ top = '999999' } @period).Options.top | Should -Be 25
        (Get-FathomReport -Name top-users -Option @{ top = 'ten' } @period).Options.top | Should -Be 25
        (Get-FathomReport -Name top-users -Option @{ top = '3' } @period).Options.top | Should -Be 3
        (Get-FathomReport -Name denials -Option @{ group = 'nonsense' } @period).Options.group | Should -Be 'feature'
    }

    It 'refuses a report that does not exist' {
        { Get-FathomReport -Name nonsense } | Should -Throw "*no report called*"
    }

    It 'groups denials by feature, by user, or lists each one' {
        $feature = (Get-FathomReport -Name denials @period).Rows
        $feature.Feature | Should -Be 'MATLAB'
        $feature.Denials | Should -Be 2
        $feature.Users | Should -Be 1
        (Get-FathomReport -Name denials -Option @{ group = 'user' } @period).Rows.User | Should -Be 'raven'
        (Get-FathomReport -Name denials -Option @{ group = 'event' } @period).Rows.Count | Should -Be 2
    }

    It 'adds hours from paired checkouts, and counts denied people too' {
        $rows = (Get-FathomReport -Name top-users -Option @{ feature = 'MATLAB' } @period).Rows
        $starfire = $rows | Where-Object User -EQ 'starfire'
        $starfire.Checkouts | Should -Be 1
        $starfire.Hours | Should -Be 0.3
        ($rows | Where-Object User -EQ 'raven').Denials | Should -Be 2
    }

    It 'limits holders to those held long enough' {
        (Get-FathomReport -Name seat-holders).Rows | Should -Not -BeNullOrEmpty
        (Get-FathomReport -Name seat-holders -Option @{ hours = '8760' }).Rows | Should -BeNullOrEmpty
    }

    It 'charts only the features picked, or the busiest few' {
        $picked = Get-FathomReport -Name usage-history -Option @{ features = 'RVT_2024' } @period
        $picked.Rows.Feature | Sort-Object -Unique | Should -Be 'RVT_2024'
        $picked.Charts.Count | Should -Be 1
        (Get-FathomReport -Name usage-history -Option @{ top = '2' } @period).Charts.Count | Should -BeLessOrEqual 2
    }

    It 'draws a single reading as a bar, since a line needs two points' {
        $report = Get-FathomReport -Name usage-history -Option @{ features = 'RVT_2024' } @period
        $report.Charts[0].Points.Count | Should -Be 1
        $report.Charts[0].Type | Should -Be 'ColumnClustered'
    }

    It 'writes a CSV a spreadsheet will not run, dates as text' {
        $path = "$TestDrive/denials.csv"
        Get-FathomReport -Name top-users @period | Export-FathomReport -Path $path
        $rows = Import-Csv -LiteralPath $path
        $rows[0].PSObject.Properties.Name | Should -Contain 'Hours held'
        ($rows | Where-Object User -Like "*HYPERLINK*").User | Should -BeLike "'=*"
        [IO.File]::ReadAllBytes($path)[0..2] | Should -Be 0xEF, 0xBB, 0xBF
    }

    It 'turns down a format it cannot write' {
        { Get-FathomReport -Name uptime @period | Export-FathomReport -Path "$TestDrive/x.pdf" } | Should -Throw
    }

    Context 'Excel' -Skip:(-not $canExcel) {
        BeforeAll {
            $open = {
                param($path)
                Import-Module ImportExcel 3> $null
                Open-ExcelPackage -Path $path
            }
        }

        It 'writes rows as data, never a formula, and says what was asked for' {
            $path = "$TestDrive/users.xlsx"
            Get-FathomReport -Name top-users @period | Export-FathomReport -Path $path
            $package = & $open $path
            $sheet = $package.Workbook.Worksheets['Report']
            $sheet.Cells['A1'].Value | Should -Be 'Top users'
            $sheet.Cells['A2'].Value | Should -BeLike '* to *'
            @($sheet.Cells | Where-Object Formula).Count | Should -Be 0
            $sheet.Tables[0].Columns[0].Name | Should -Be 'User'
            Close-ExcelPackage $package -NoSave
        }

        It 'adds a chart per feature for usage history' {
            $path = "$TestDrive/usage.xlsx"
            $report = Get-FathomReport -Name usage-history -Option @{ top = '3' } @period
            $report | Export-FathomReport -Path $path
            $package = & $open $path
            $package.Workbook.Worksheets.Name | Should -Be 'Report', 'Charts', 'Chart data'
            $package.Workbook.Worksheets['Charts'].Drawings.Count | Should -Be $report.Charts.Count
            $package.Workbook.Worksheets['Charts'].Drawings[0].Series.Count | Should -Be 2
            Close-ExcelPackage $package -NoSave
        }

        It 'adds one chart of the busiest features to seat planning' {
            $path = "$TestDrive/seats.xlsx"
            Get-FathomReport -Name seat-planning @period | Export-FathomReport -Path $path
            $package = & $open $path
            $package.Workbook.Worksheets['Charts'].Drawings[0].Series.Count | Should -Be 3
            Close-ExcelPackage $package -NoSave
        }
    }
}
