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
