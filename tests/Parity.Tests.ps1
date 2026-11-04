# Golden files come from Python Fathom's own parsers: see fixtures/generate_golden.py.
# Pinned values here must match the ones there.
BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../Modules/Fathom/Fathom.psd1') -Force

    # One comparable line per row. Dates are normalised because ConvertFrom-Json may parse them.
    function ConvertTo-ComparableRow([System.Collections.IDictionary] $Row) {
        ($Row.Keys | ForEach-Object {
            $value = $Row[$_]
            if ($value -is [datetime]) {
                $value = $value.ToString('s')
            }
            "$_=$value"
        }) -join ' | '
    }

    function Get-GoldenRow([string] $Path) {
        foreach ($row in Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable) {
            ConvertTo-ComparableRow $row
        }
    }
}

Describe 'Debug-log parity with Python Fathom: <Name>' -ForEach (
    Get-ChildItem -Path "$PSScriptRoot/fixtures" -Filter '*.log' | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
) {
    It 'parses every line into the same events' {
        $context = New-FathomParserContext -ServerId parity -SourceFile $Name -SourceHash parity -BatchId parity -CurrentDate '2026-01-01'

        $actual = [System.IO.File]::ReadLines($Path) | ConvertFrom-FathomDebugLog -Context $context | ForEach-Object {
            ConvertTo-ComparableRow ([ordered] @{
                    event_id           = $_.EventId
                    event_type         = $_.EventType
                    timestamp          = $_.Timestamp
                    server_format      = $_.ServerFormat
                    server_id          = $_.ServerId
                    feature            = $_.Feature
                    vendor_daemon      = $_.VendorDaemon
                    user               = $_.User
                    host               = $_.Host
                    display            = $_.Display
                    version            = $_.Version
                    licenses_in_use    = $_.LicensesInUse
                    licenses_available = $_.LicensesAvailable
                    queue_position     = $_.QueuePosition
                    handle             = $_.Handle
                    unit_count         = $_.UnitCount
                    raw_line           = $_.RawLine
                    source_file        = $_.SourceFile
                    line_number        = $_.LineNumber
                    ingest_batch_id    = $_.IngestBatchId
                })
        }

        $actual | Should -Be (Get-GoldenRow ($Path -replace '\.log$', '.events.json'))
    }
}

Describe 'lmstat parity with Python Fathom: <Name>' -ForEach (
    Get-ChildItem -Path "$PSScriptRoot/fixtures" -Filter '*lmstat*.txt' | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
) {
    It 'captures the same feature snapshots' {
        $actual = Get-Content -LiteralPath $Path | ConvertFrom-FathomLmstat -ServerId parity -CapturedAt '2026-08-20T12:00:00' | ForEach-Object {
            ConvertTo-ComparableRow ([ordered] @{
                    server_id       = $_.ServerId
                    feature         = $_.Feature
                    licenses_issued = $_.LicensesIssued
                    licenses_in_use = $_.LicensesInUse
                    vendor_daemon   = $_.VendorDaemon
                    captured_at     = $_.CapturedAt
                })
        }

        $actual | Should -Be (Get-GoldenRow ($Path -replace '\.txt$', '.status.json'))
    }
}
