-- Fathom monitoring tables. Shared tables are copied verbatim from
-- license_manager/src/lm_opdb so the Python and PowerShell versions can use one
-- database; tables marked "fathom-ps only" are this app's own. Every statement
-- is idempotent: keep it that way.

-- Usage history parsed from lmgrd debug logs (lm_opdb/license_events.py).
CREATE TABLE IF NOT EXISTS license_events (
    event_id TEXT PRIMARY KEY,
    event_type TEXT NOT NULL,
    timestamp TIMESTAMP NOT NULL,
    server_format TEXT NOT NULL,
    server_id TEXT NOT NULL,
    feature TEXT,
    vendor_daemon TEXT,
    "user" TEXT,
    host TEXT,
    display TEXT,
    version TEXT,
    licenses_in_use INTEGER,
    licenses_available INTEGER,
    queue_position INTEGER,
    handle TEXT,
    unit_count INTEGER NOT NULL DEFAULT 1,
    raw_line TEXT NOT NULL,
    source_file TEXT NOT NULL,
    line_number INTEGER NOT NULL,
    ingest_batch_id TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS license_events_server_ts ON license_events (server_id, timestamp);
CREATE INDEX IF NOT EXISTS license_events_user ON license_events ("user");
CREATE INDEX IF NOT EXISTS license_events_type ON license_events (event_type);

-- Latest lmstat snapshot per feature (lm_opdb/live_status.py).
CREATE TABLE IF NOT EXISTS live_status (
    server_id TEXT,
    feature TEXT,
    licenses_issued INTEGER,
    licenses_in_use INTEGER,
    vendor_daemon TEXT,
    captured_at TIMESTAMP,
    PRIMARY KEY (server_id, feature)
);

-- Seat limits and entitlement per feature (lm_opdb/feature_inventory.py).
CREATE TABLE IF NOT EXISTS feature_inventory (
    server_id TEXT,
    feature TEXT,
    vendor_daemon TEXT,
    version TEXT,
    licenses_issued INTEGER,
    expiration DATE,
    cost NUMERIC,
    updated_at TIMESTAMP,
    PRIMARY KEY (server_id, feature)
);
ALTER TABLE feature_inventory ADD COLUMN IF NOT EXISTS token_family TEXT;

-- Read position per log file (lm_opdb/manifest.py). Shared with Fathom: this
-- app's rows use file_key 'psu:<server_id>:<first-line hash>'.
CREATE TABLE IF NOT EXISTS _ingest_manifest (
    file_key TEXT PRIMARY KEY,
    last_known_path TEXT,
    server_id TEXT,
    resume_offset BIGINT,
    line_number BIGINT,
    resolved_date TIMESTAMP,
    last_batch_id TEXT,
    last_ingested_at TIMESTAMP,
    total_events_written BIGINT
);

-- fathom-ps only (not in Python Fathom): the license servers this app monitors.
CREATE TABLE IF NOT EXISTS monitored_servers (
    server_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    license_spec TEXT,
    log_path TEXT,
    vendor TEXT,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    CHECK (license_spec IS NOT NULL OR log_path IS NOT NULL)
);
-- Result of the latest lmstat poll (fathom-ps only).
ALTER TABLE monitored_servers ADD COLUMN IF NOT EXISTS last_polled_at TIMESTAMP;
ALTER TABLE monitored_servers ADD COLUMN IF NOT EXISTS last_poll_status TEXT;
ALTER TABLE monitored_servers ADD COLUMN IF NOT EXISTS last_poll_message TEXT;
