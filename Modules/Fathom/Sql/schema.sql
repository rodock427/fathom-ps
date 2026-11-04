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

-- Health of each server's debug log, to spot a share that quietly stopped (fathom-ps only).
ALTER TABLE monitored_servers ADD COLUMN IF NOT EXISTS last_log_read_at TIMESTAMP;
ALTER TABLE monitored_servers ADD COLUMN IF NOT EXISTS last_log_line_at TIMESTAMP;
ALTER TABLE monitored_servers ADD COLUMN IF NOT EXISTS last_log_status TEXT;
ALTER TABLE monitored_servers ADD COLUMN IF NOT EXISTS last_log_error TEXT;

-- Which source drives usage history: the debug log, lmstat, or auto (log while healthy).
ALTER TABLE monitored_servers ADD COLUMN IF NOT EXISTS usage_source TEXT NOT NULL DEFAULT 'auto';
DO $$ BEGIN
    ALTER TABLE monitored_servers ADD CONSTRAINT monitored_servers_usage_source_check
        CHECK (usage_source IN ('auto', 'log', 'lmstat'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Every lmstat snapshot, so lmstat-only servers have a usage history too (fathom-ps only).
CREATE TABLE IF NOT EXISTS usage_samples (
    server_id TEXT NOT NULL,
    feature TEXT NOT NULL,
    captured_at TIMESTAMP NOT NULL,
    licenses_issued INTEGER NOT NULL,
    licenses_in_use INTEGER NOT NULL,
    PRIMARY KEY (server_id, feature, captured_at)
);

-- Who holds each seat right now, per lmstat; replaced on every poll (fathom-ps only).
CREATE TABLE IF NOT EXISTS live_sessions (
    server_id TEXT NOT NULL,
    feature TEXT NOT NULL,
    "user" TEXT NOT NULL,
    host TEXT,
    display TEXT,
    version TEXT,
    handle TEXT,
    licenses INTEGER NOT NULL DEFAULT 1,
    started_at TIMESTAMP,
    captured_at TIMESTAMP NOT NULL
);
CREATE INDEX IF NOT EXISTS live_sessions_server ON live_sessions (server_id);

-- Each vendor daemon's state per lmstat; replaced on every poll (fathom-ps only).
CREATE TABLE IF NOT EXISTS vendor_daemon_status (
    server_id TEXT NOT NULL,
    daemon TEXT NOT NULL,
    up BOOLEAN NOT NULL,
    detail TEXT,
    captured_at TIMESTAMP NOT NULL,
    PRIMARY KEY (server_id, daemon)
);

-- Outcome of every lmstat poll, for uptime and "down for how long" (fathom-ps only).
CREATE TABLE IF NOT EXISTS poll_history (
    server_id TEXT NOT NULL,
    polled_at TIMESTAMP NOT NULL,
    status TEXT NOT NULL,
    PRIMARY KEY (server_id, polled_at)
);

-- One row per checkout session seen by lmstat, so lmstat-only servers have session
-- lengths and active users too. last_seen_at moves on every poll that still shows it.
CREATE TABLE IF NOT EXISTS observed_sessions (
    server_id TEXT NOT NULL,
    feature TEXT NOT NULL,
    "user" TEXT NOT NULL,
    host TEXT NOT NULL,
    handle TEXT NOT NULL,
    started_at TIMESTAMP NOT NULL,
    licenses INTEGER NOT NULL,
    first_seen_at TIMESTAMP NOT NULL,
    last_seen_at TIMESTAMP NOT NULL,
    PRIMARY KEY (server_id, feature, "user", host, handle, started_at)
);
CREATE INDEX IF NOT EXISTS observed_sessions_user ON observed_sessions ("user");

-- The time span each ingested log file covers (fathom-ps only). Gaps between spans (before
-- monitoring began, or lines lost to rotation) are where Auto falls back to lmstat.
CREATE TABLE IF NOT EXISTS log_coverage (
    file_key TEXT PRIMARY KEY,
    server_id TEXT NOT NULL,
    first_event_at TIMESTAMP NOT NULL,
    last_event_at TIMESTAMP NOT NULL
);
CREATE INDEX IF NOT EXISTS log_coverage_server ON log_coverage (server_id);

-- Alert settings: one row, edited with Set-FathomAlertSetting (fathom-ps only).
-- Sending is off until enabled; alerts are still evaluated and recorded meanwhile.
CREATE TABLE IF NOT EXISTS alert_settings (
    id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    enabled BOOLEAN NOT NULL DEFAULT FALSE,
    smtp_server TEXT,
    smtp_port INTEGER NOT NULL DEFAULT 25,
    use_ssl BOOLEAN NOT NULL DEFAULT TRUE,
    mail_from TEXT,
    mail_to TEXT,
    -- Testing only: write each message as an .eml file here instead of sending it.
    pickup_directory TEXT,
    down_minutes INTEGER NOT NULL DEFAULT 10,
    capacity_minutes INTEGER NOT NULL DEFAULT 30,
    expiry_days INTEGER NOT NULL DEFAULT 30,
    repeat_hours INTEGER NOT NULL DEFAULT 24,
    updated_at TIMESTAMP
);
INSERT INTO alert_settings (id) VALUES (1) ON CONFLICT DO NOTHING;

-- Every alert raised, so each is mailed once, reminded on a schedule, and its resolution
-- reported (fathom-ps only).
CREATE TABLE IF NOT EXISTS alert_state (
    alert_key TEXT PRIMARY KEY,
    rule TEXT NOT NULL,
    severity TEXT NOT NULL,
    server_id TEXT,
    feature TEXT,
    message TEXT NOT NULL,
    first_seen_at TIMESTAMP NOT NULL,
    last_seen_at TIMESTAMP NOT NULL,
    last_notified_at TIMESTAMP,
    resolved_at TIMESTAMP,
    resolution_notified BOOLEAN NOT NULL DEFAULT FALSE
);
-- When the condition itself began (e.g. the first failed poll), if the rule knows.
ALTER TABLE alert_state ADD COLUMN IF NOT EXISTS condition_since TIMESTAMP;

-- Active Directory details behind FlexLM usernames and hosts (fathom-ps only; Python Fathom's
-- user_directory / directory_attributes are a different model and are left alone).
-- Only attributes marked recorded are stored; name is lower case (a host without its domain).
CREATE TABLE IF NOT EXISTS ad_objects (
    kind TEXT NOT NULL CHECK (kind IN ('user', 'computer')),
    name TEXT NOT NULL,
    found BOOLEAN NOT NULL,
    attributes JSONB NOT NULL DEFAULT '{}',
    fetched_at TIMESTAMP NOT NULL,
    PRIMARY KEY (kind, name)
);

-- Every attribute name the directory has returned, and whether its values are recorded and
-- shown. Names only: no values are kept here.
CREATE TABLE IF NOT EXISTS ad_attributes (
    kind TEXT NOT NULL CHECK (kind IN ('user', 'computer')),
    name TEXT NOT NULL,
    recorded BOOLEAN NOT NULL DEFAULT FALSE,
    shown BOOLEAN NOT NULL DEFAULT FALSE,
    first_seen_at TIMESTAMP NOT NULL,
    PRIMARY KEY (kind, name),
    CHECK (recorded OR NOT shown)
);

-- Directory lookups: one row, off by default.
CREATE TABLE IF NOT EXISTS ad_settings (
    id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    enabled BOOLEAN NOT NULL DEFAULT FALSE,
    -- A domain controller or domain to ask; the PSU server's own domain when empty.
    server TEXT,
    refresh_hours INTEGER NOT NULL DEFAULT 24,
    updated_at TIMESTAMP
);
INSERT INTO ad_settings (id) VALUES (1) ON CONFLICT DO NOTHING;
