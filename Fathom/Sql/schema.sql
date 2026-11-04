-- Fathom monitoring tables. Copied verbatim from license_manager/src/lm_opdb so
-- the Python and PowerShell versions can share one database. Every statement is
-- idempotent: keep it that way.

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
