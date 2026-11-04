# Needs a throwaway Postgres (FATHOM_TEST_DSN) and a Unix shell for the fake lmutil.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester shares BeforeAll variables with It blocks.')]
param()

Describe 'tools/New-DevData.ps1' -Skip:(-not $env:FATHOM_TEST_DSN -or $IsWindows) {
    BeforeAll {
        $tool = Join-Path -Path $PSScriptRoot -ChildPath '../tools/New-DevData.ps1'
        $summary = & $tool -Dsn $env:FATHOM_TEST_DSN -DevDirectory $TestDrive -Days 3 -Confirm:$false

        Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../Modules/Fathom/Fathom.psd1') -Force
        Connect-FathomDatabase -Dsn $env:FATHOM_TEST_DSN
    }

    AfterAll {
        $null = & $tool -Dsn $env:FATHOM_TEST_DSN -DevDirectory $TestDrive -Remove -Confirm:$false
        Disconnect-FathomDatabase
    }

    It 'writes a debug log that parses completely and agrees with lmstat' {
        $summary.LogEvents | Should -BeGreaterThan 0
        $health = Get-FathomServerHealth -ServerId dev-licsrv

        $health.Status | Should -Be 'Healthy'
        $health.UnparsedLines | Should -Be 0
        $health.LogDrift | Should -Be 0 -Because 'the log and the lmstat answer come from the same sessions'
        $health.SeatsInUse | Should -Be $summary.Holding
    }

    It 'never puts more people on a feature than it has seats' {
        foreach ($feature in Get-FathomCapacityReport -ServerId dev-licsrv -From (Get-Date).AddDays(-3)) {
            $feature.Peak | Should -BeLessOrEqual $feature.Seats -Because $feature.Feature
        }
    }

    It 'refuses a database that is not on this machine' {
        { & $tool -Dsn 'postgresql://u:p@db01.corp.example:5432/fathom' -DevDirectory $TestDrive } | Should -Throw '*only writes to a database on this machine*'
    }
}
