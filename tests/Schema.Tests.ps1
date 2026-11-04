# Needs a throwaway Postgres: set FATHOM_TEST_DSN. Never point it at a real database.
BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../Modules/Fathom/Fathom.psd1') -Force

    function Get-TableColumn([string] $Table) {
        $query = 'SELECT column_name FROM information_schema.columns WHERE table_name = @table ORDER BY ordinal_position'
        (Invoke-SqlQuery -ConnectionName Fathom -Query $query -Parameters @{ table = $Table }).column_name
    }
}

Describe 'Initialize-FathomSchema' -Skip:(-not $env:FATHOM_TEST_DSN) {
    BeforeAll {
        Connect-FathomDatabase -Dsn $env:FATHOM_TEST_DSN
        Invoke-SqlUpdate -ConnectionName Fathom -Query 'DROP TABLE IF EXISTS license_events, live_status, feature_inventory, _ingest_manifest, monitored_servers'
        Initialize-FathomSchema
    }

    AfterAll {
        Disconnect-FathomDatabase
    }

    It 'is idempotent' {
        { Initialize-FathomSchema } | Should -Not -Throw
    }

    # Column lists mirror license_manager/src/lm_opdb. A mismatch means the two apps can't share a database.
    It 'creates <Table> with the same columns as Fathom' -ForEach @(
        @{
            Table   = 'license_events'
            Columns = 'event_id', 'event_type', 'timestamp', 'server_format', 'server_id', 'feature',
            'vendor_daemon', 'user', 'host', 'display', 'version', 'licenses_in_use',
            'licenses_available', 'queue_position', 'handle', 'unit_count', 'raw_line',
            'source_file', 'line_number', 'ingest_batch_id'
        }
        @{
            Table   = 'live_status'
            Columns = 'server_id', 'feature', 'licenses_issued', 'licenses_in_use', 'vendor_daemon', 'captured_at'
        }
        @{
            Table   = 'feature_inventory'
            Columns = 'server_id', 'feature', 'vendor_daemon', 'version', 'licenses_issued',
            'expiration', 'cost', 'updated_at', 'token_family'
        }
        @{
            Table   = '_ingest_manifest'
            Columns = 'file_key', 'last_known_path', 'server_id', 'resume_offset', 'line_number',
            'resolved_date', 'last_batch_id', 'last_ingested_at', 'total_events_written'
        }
    ) {
        Get-TableColumn -Table $Table | Should -Be $Columns
    }
}
