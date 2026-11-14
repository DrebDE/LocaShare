-- LocaShare Database Schema (SQLite)
-- Multi-device privacy-first location sharing with short-lived pairing codes
-- and authenticated dashboard sessions.
-- Stores ONLY the latest location per device by default (no route history).

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS devices (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id       TEXT    NOT NULL UNIQUE,
    device_name     TEXT    NOT NULL DEFAULT 'Android Phone',
    token_hash      TEXT    NOT NULL,
    registered_at   TEXT    NOT NULL,
    unregistered_at TEXT    NULL,
    updated_at      TEXT    NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_devices_active
    ON devices (unregistered_at, device_id);

CREATE TABLE IF NOT EXISTS device_status (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id            INTEGER NOT NULL UNIQUE REFERENCES devices(id) ON DELETE CASCADE,
    sharing_enabled      INTEGER NOT NULL DEFAULT 0,
    status_state         TEXT    NOT NULL DEFAULT 'registered',
    battery_percentage   INTEGER NULL,
    is_charging          INTEGER NULL,
    network_status       TEXT    NULL DEFAULT 'unknown',
    last_latitude        REAL    NULL,
    last_longitude       REAL    NULL,
    last_accuracy        REAL    NULL,
    location_recorded_at TEXT    NULL,
    location_received_at TEXT    NULL,
    last_heartbeat_at    TEXT    NULL,
    updated_at           TEXT    NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_device_status_device
    ON device_status (device_id);

CREATE TABLE IF NOT EXISTS pairing_codes (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id   INTEGER NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    code_hash   TEXT    NOT NULL UNIQUE,
    expires_at  TEXT    NOT NULL,
    used_at     TEXT    NULL,
    revoked_at  TEXT    NULL,
    created_at  TEXT    NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_pairing_device_active
    ON pairing_codes (device_id, expires_at, used_at, revoked_at);

CREATE TABLE IF NOT EXISTS dashboard_sessions (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    session_hash TEXT    NOT NULL UNIQUE,
    csrf_token   TEXT    NOT NULL,
    label        TEXT    NOT NULL DEFAULT 'Laptop Browser',
    created_at   TEXT    NOT NULL,
    last_seen_at TEXT    NOT NULL,
    expires_at   TEXT    NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sessions_expiry
    ON dashboard_sessions (expires_at);

CREATE TABLE IF NOT EXISTS dashboard_device_pairings (
    id                         INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id                 INTEGER NOT NULL REFERENCES dashboard_sessions(id) ON DELETE CASCADE,
    device_id                  INTEGER NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    paired_at                  TEXT    NOT NULL,
    revoked_at                 TEXT    NULL,
    revoked_by                 TEXT    NULL,
    revocation_acknowledged_at TEXT    NULL,
    UNIQUE (session_id, device_id)
);

CREATE INDEX IF NOT EXISTS idx_pairings_session_active
    ON dashboard_device_pairings (session_id, revoked_at);

CREATE INDEX IF NOT EXISTS idx_pairings_device_active
    ON dashboard_device_pairings (device_id, revoked_at);
