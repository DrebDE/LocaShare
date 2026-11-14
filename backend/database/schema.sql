-- LocaShare Database Schema (MySQL / MariaDB)
-- Multi-device privacy-first location sharing with short-lived pairing codes
-- and authenticated dashboard sessions.
-- Stores ONLY the latest location per device by default (no route history).

CREATE DATABASE IF NOT EXISTS locashare
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE locashare;

-- ============================================================
-- Table: devices
-- Each Android device self-registers and receives a unique
-- device_id and high-entropy token (only SHA-256 hash stored).
-- ============================================================
CREATE TABLE IF NOT EXISTS devices (
    id              INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    device_id       VARCHAR(64)  NOT NULL UNIQUE,
    device_name     VARCHAR(64)  NOT NULL DEFAULT 'Android Phone',
    token_hash      VARCHAR(255) NOT NULL,
    registered_at   DATETIME     NOT NULL,
    unregistered_at DATETIME     NULL,
    updated_at      DATETIME     NOT NULL,

    INDEX idx_devices_active (unregistered_at, device_id)
) ENGINE=InnoDB;

-- ============================================================
-- Table: device_status
-- Latest-only location and separate phone heartbeat state.
-- ============================================================
CREATE TABLE IF NOT EXISTS device_status (
    id                   INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    device_id            INT UNSIGNED     NOT NULL UNIQUE,
    sharing_enabled      TINYINT(1)       NOT NULL DEFAULT 0,
    status_state         VARCHAR(32)      NOT NULL DEFAULT 'registered',
    battery_percentage   TINYINT UNSIGNED NULL,
    is_charging          TINYINT(1)       NULL,
    network_status       VARCHAR(20)      NULL DEFAULT 'unknown',
    last_latitude        DECIMAL(10, 7)   NULL,
    last_longitude       DECIMAL(10, 7)   NULL,
    last_accuracy        FLOAT            NULL,
    location_recorded_at DATETIME         NULL COMMENT 'UTC time phone captured the fix',
    location_received_at DATETIME         NULL COMMENT 'UTC time backend received the fix',
    last_heartbeat_at    DATETIME         NULL COMMENT 'UTC time phone last checked in',
    updated_at           DATETIME         NOT NULL,

    FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE,
    INDEX idx_device_status_device (device_id)
) ENGINE=InnoDB;

-- ============================================================
-- Table: pairing_codes
-- Short-lived, single-use pairing codes (only SHA-256 hash stored).
-- ============================================================
CREATE TABLE IF NOT EXISTS pairing_codes (
    id          INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    device_id   INT UNSIGNED NOT NULL,
    code_hash   CHAR(64)     NOT NULL UNIQUE,
    expires_at  DATETIME     NOT NULL,
    used_at     DATETIME     NULL,
    revoked_at  DATETIME     NULL,
    created_at  DATETIME     NOT NULL,

    FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE,
    INDEX idx_pairing_device_active (device_id, expires_at, used_at, revoked_at)
) ENGINE=InnoDB;

-- ============================================================
-- Table: dashboard_sessions
-- Browser dashboard sessions authenticated via HttpOnly cookies.
-- Only SHA-256 hash of the session token is persisted.
-- ============================================================
CREATE TABLE IF NOT EXISTS dashboard_sessions (
    id           INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    session_hash CHAR(64)     NOT NULL UNIQUE,
    csrf_token   CHAR(64)     NOT NULL,
    label        VARCHAR(64)  NOT NULL DEFAULT 'Laptop Browser',
    created_at   DATETIME     NOT NULL,
    last_seen_at DATETIME     NOT NULL,
    expires_at   DATETIME     NOT NULL,

    INDEX idx_sessions_expiry (expires_at)
) ENGINE=InnoDB;

-- ============================================================
-- Table: dashboard_device_pairings
-- Authorizes a specific dashboard session to read a specific device.
-- Can be revoked immediately by either phone owner or dashboard.
-- ============================================================
CREATE TABLE IF NOT EXISTS dashboard_device_pairings (
    id                         INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    session_id                 INT UNSIGNED NOT NULL,
    device_id                  INT UNSIGNED NOT NULL,
    paired_at                  DATETIME     NOT NULL,
    revoked_at                 DATETIME     NULL,
    revoked_by                 VARCHAR(16)  NULL,
    revocation_acknowledged_at DATETIME     NULL,

    UNIQUE KEY uniq_session_device (session_id, device_id),
    FOREIGN KEY (session_id) REFERENCES dashboard_sessions(id) ON DELETE CASCADE,
    FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE,
    INDEX idx_pairings_session_active (session_id, revoked_at),
    INDEX idx_pairings_device_active (device_id, revoked_at)
) ENGINE=InnoDB;
