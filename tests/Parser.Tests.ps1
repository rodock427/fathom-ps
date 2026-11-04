# Behaviour the parity tests don't spell out: resuming, context state, input shapes.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester shares BeforeAll variables with It blocks.')]
param()

BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../Modules/Fathom/Fathom.psd1') -Force

    $source = @{ ServerId = 'licsrv01'; SourceFile = 'debug.log' }
}

Describe 'ConvertFrom-FathomDebugLog' {
    It 'resumes a log across reads using the saved line number and date' {
        $first = New-FathomParserContext @source
        $null = '10:00:00 (mlm) TIMESTAMP 3/4/2026', '' | ConvertFrom-FathomDebugLog -Context $first

        $resumed = New-FathomParserContext @source -CurrentDate $first.CurrentDate -LineNumber $first.LineNumber
        $parsed = '10:05:00 (mlm) OUT: "MATLAB" alice@ws01' | ConvertFrom-FathomDebugLog -Context $resumed

        $parsed.Timestamp | Should -Be ([datetime] '2026-03-04T10:05:00')
        $parsed.LineNumber | Should -Be 3
    }

    It 'emits nothing for TIMESTAMP and blank lines, but still counts them' {
        $context = New-FathomParserContext @source
        $events = '10:00:00 (mlm) TIMESTAMP 3/4/2026', '', '   ' | ConvertFrom-FathomDebugLog -Context $context

        $events | Should -BeNullOrEmpty
        $context.LineNumber | Should -Be 3
        $context.CurrentDate | Should -Be ([datetime] '2026-03-04')
    }

    It 'gives the same line at the same position the same id, and a new position a new id' {
        $line = '10:05:00 (mlm) OUT: "MATLAB" alice@ws01'
        $a = $line | ConvertFrom-FathomDebugLog -Context (New-FathomParserContext @source)
        $b = $line | ConvertFrom-FathomDebugLog -Context (New-FathomParserContext @source)
        $c = $line | ConvertFrom-FathomDebugLog -Context (New-FathomParserContext @source -LineNumber 1)

        $a.EventId | Should -Be $b.EventId
        $c.EventId | Should -Not -Be $a.EventId
    }

    It 'keeps unrecognised lines as unsupported events with their logged time' {
        $context = New-FathomParserContext @source -CurrentDate '2026-03-04'
        $parsed = '10:06:07 (mlm) Something new from a future lmgrd' | ConvertFrom-FathomDebugLog -Context $context

        $parsed.EventType | Should -Be 'unsupported'
        $parsed.Timestamp | Should -Be ([datetime] '2026-03-04T10:06:07')
    }
}

Describe 'ConvertFrom-FathomLmstat' {
    It 'accepts the whole output as one string' {
        $text = "Users of MATLAB:  (Total of 10 licenses issued;  Total of 3 licenses in use)`n`n  `"MATLAB`" v1, vendor: mlm, expiry: x"
        $status = ConvertFrom-FathomLmstat -InputObject $text -ServerId licsrv01

        $status.Feature | Should -Be 'MATLAB'
        $status.VendorDaemon | Should -Be 'mlm'
    }

    It 'produces nothing for a server it could not reach' {
        'Error getting status: Cannot connect to license server system. (-15,570:111)' |
            ConvertFrom-FathomLmstat -ServerId licsrv01 | Should -BeNullOrEmpty
    }

    It 'leaves the vendor empty when the next feature starts first' {
        $statuses = @(
            'Users of A:  (Total of 1 license issued;  Total of 0 licenses in use)'
            'Users of B:  (Total of 2 licenses issued;  Total of 1 license in use)'
            '  "B" v1, vendor: mlm, expiry: x'
        ) | ConvertFrom-FathomLmstat -ServerId licsrv01

        $statuses.VendorDaemon | Should -Be @($null, 'mlm')
    }
}

Describe 'ConvertFrom-FathomLmstat holders and expiry' {
    BeforeAll {
        $detail = Get-Content -Raw -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'fixtures/lmstat_detail.txt')
        $statuses = ConvertFrom-FathomLmstat -InputObject $detail -ServerId licsrv01 -CapturedAt '2026-11-02T14:30:00'
        $acad = $statuses | Where-Object Feature -EQ '87545ACD_2026_0F'
    }

    It 'lists each holder with host, seats and start time' {
        $acad.Holders.User | Should -Be @('alice', 'bob', 'carol')
        $bob = $acad.Holders | Where-Object User -EQ 'bob'
        $bob.Host | Should -Be 'ws-02.corp.local'
        $bob.Licenses | Should -Be 2
        $bob.Handle | Should -Be '2202'
        $bob.StartedAt | Should -Be ([datetime] '2026-11-02T09:41:00')
    }

    It 'puts a start date that would be in the future into last year' {
        $dave = ($statuses | Where-Object Feature -EQ 'INVENTOR_PRO').Holders | Where-Object User -EQ 'dave'
        $dave.StartedAt | Should -Be ([datetime] '2025-12-28T23:50:00')
    }

    It 'reads a dated expiry, and both spellings of permanent' {
        $acad.Expiry | Should -Be ([datetime] '2027-03-31')
        foreach ($feature in 'INVENTOR_PRO', 'RVT_2024') {
            $permanent = $statuses | Where-Object Feature -EQ $feature
            $permanent.Expiry | Should -BeNullOrEmpty -Because "$feature never expires"
            $permanent.ExpiryReported | Should -BeTrue
        }
    }

    It 'marks expiry as unreported when lmstat leaves it out' {
        $status = "Users of X:  (Total of 1 license issued;  Total of 0 licenses in use)`n  `"X`" v1, vendor: mlm," |
            ConvertFrom-FathomLmstat -ServerId licsrv01
        $status.ExpiryReported | Should -BeFalse
    }

    It 'resolves a Feb 29 start seen in a non-leap year' {
        InModuleScope Fathom {
            Resolve-FathomLmstatStart -Month 2 -Day 29 -Hour 9 -Minute 0 -CapturedAt '2029-03-01T10:00:00'
        } | Should -Be ([datetime] '2028-02-29T09:00:00')
    }
}

Describe 'Get-FathomLmstatHealth' {
    It 'reads lmgrd and each vendor daemon' {
        $detail = Get-Content -Raw -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'fixtures/lmstat_detail.txt')
        $health = InModuleScope Fathom -Parameters @{ Output = $detail } { param($Output) Get-FathomLmstatHealth -Output $Output }

        $health.ServerUp | Should -BeTrue
        $health.Daemons.Name | Should -Be @('adskflex', 'mlm')
        $health.Daemons.Up | Should -Be @($true, $false)
        $health.Daemons[0].Detail | Should -Be 'UP v11.19.4'
        $health.Daemons[1].Detail | Should -BeLike 'The desired vendor daemon is down*'
    }
}

Describe 'Midnight rollover' {
    It 'moves the date on when the clock wraps past midnight' {
        $context = New-FathomParserContext @source -CurrentDate '2026-03-04'
        $parsed = '23:59:00 (mlm) OUT: "MATLAB" alice@ws01', '00:01:00 (mlm) IN: "MATLAB" alice@ws01' |
            ConvertFrom-FathomDebugLog -Context $context

        $parsed.Timestamp | Should -Be @([datetime] '2026-03-04T23:59:00', [datetime] '2026-03-05T00:01:00')
    }

    It 'treats a small step back as a clock change, not a new day' {
        $context = New-FathomParserContext @source -CurrentDate '2026-11-01'
        $parsed = '01:59:00 (mlm) OUT: "MATLAB" alice@ws01', '01:05:00 (mlm) IN: "MATLAB" alice@ws01' |
            ConvertFrom-FathomDebugLog -Context $context

        $parsed[1].Timestamp | Should -Be ([datetime] '2026-11-01T01:05:00')
    }

    It 'notices a midnight that falls between two reads' {
        $first = New-FathomParserContext @source -CurrentDate '2026-03-04'
        $null = '23:58:00 (mlm) OUT: "MATLAB" alice@ws01' | ConvertFrom-FathomDebugLog -Context $first

        $resumed = New-FathomParserContext @source -CurrentDate $first.CurrentDate -LastTime $first.LastTime -LineNumber $first.LineNumber
        $parsed = '00:02:00 (mlm) IN: "MATLAB" alice@ws01' | ConvertFrom-FathomDebugLog -Context $resumed

        $parsed.Timestamp | Should -Be ([datetime] '2026-03-05T00:02:00')
    }

    It 'takes a TIMESTAMP line''s date as given, without rolling over again' {
        $context = New-FathomParserContext @source -CurrentDate '2026-03-04'
        $parsed = '23:59:00 (mlm) OUT: "MATLAB" alice@ws01', '00:00:10 (mlm) TIMESTAMP 3/5/2026', '00:01:00 (mlm) IN: "MATLAB" alice@ws01' |
            ConvertFrom-FathomDebugLog -Context $context

        $parsed[1].Timestamp | Should -Be ([datetime] '2026-03-05T00:01:00')
    }
}
