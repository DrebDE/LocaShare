-- LocaShare Database Schema (MySQL / MariaDB)
-- Multi-device privacy-first location sharing + Life360-style Family Circles,
-- Home Geofencing, Saved Places (Home, School, Work), and Enter/Exit Events.
-- Stores ONLY the latest location per device by default (no route history).

CREATE DATABASE IF NOT EXISTS locashare
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE locashare;

-- ============================================================
-- Table: devices
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
-- Latest-only location, Home geofence presence, and heartbeat state.
-- ============================================================
CREATE TABLE IF NOT EXISTS device_status (
    id                   INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    device_id            INT UNSIGNED     NOT NULL UNIQUE,
    sharing_enabled      TINYINT(1)       NOT NULL DEFAULT 0,
    status_state         VARCHAR(32)      NOT NULL DEFAULT 'registered',
    presence_mode        VARCHAR(16)      NOT NULL DEFAULT 'unknown',
    current_place_id     VARCHAR(64)      NULL,
    current_place_name   VARCHAR(64)      NULL,
    home_privacy_masked  TINYINT(1)       NOT NULL DEFAULT 0,
    smart_home_mode      TINYINT(1)       NOT NULL DEFAULT 1,
    speed_mps            FLOAT            NULL,
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

-- ============================================================
-- Table: family_circles
-- Shared family groups joined via shareable invite code (FAM-XXXX-XXXX).
-- ============================================================
CREATE TABLE IF NOT EXISTS family_circles (
    id                   INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    circle_id            VARCHAR(64)  NOT NULL UNIQUE,
    name                 VARCHAR(64)  NOT NULL,
    invite_code          VARCHAR(32)  NOT NULL,
    invite_code_hash     CHAR(64)     NOT NULL UNIQUE,
    created_by_device_id INT UNSIGNED NOT NULL,
    created_at           DATETIME     NOT NULL,
    updated_at           DATETIME     NOT NULL,

    FOREIGN KEY (created_by_device_id) REFERENCES devices(id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- ============================================================
-- Table: circle_members
-- ============================================================
CREATE TABLE IF NOT EXISTS circle_members (
    id           INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    circle_id    INT UNSIGNED NOT NULL,
    device_id    INT UNSIGNED NOT NULL,
    member_name  VARCHAR(64)  NOT NULL,
    role         VARCHAR(16)  NOT NULL DEFAULT 'member',
    avatar_color VARCHAR(16)  NOT NULL DEFAULT '#0EA5E9',
    joined_at    DATETIME     NOT NULL,
    left_at      DATETIME     NULL,

    UNIQUE KEY uniq_circle_device (circle_id, device_id),
    FOREIGN KEY (circle_id) REFERENCES family_circles(id) ON DELETE CASCADE,
    FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE,
    INDEX idx_circle_members_active (device_id, left_at),
    INDEX idx_circle_members_circle (circle_id, left_at)
) ENGINE=InnoDB;

-- ============================================================
-- Table: saved_places
-- Home, School, Work, and Custom geofence zones per Family Circle.
-- ============================================================
CREATE TABLE IF NOT EXISTS saved_places (
    id                   INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    place_id             VARCHAR(64)    NOT NULL UNIQUE,
    circle_id            INT UNSIGNED   NOT NULL,
    name                 VARCHAR(64)    NOT NULL,
    category             VARCHAR(16)    NOT NULL DEFAULT 'custom',
    latitude             DECIMAL(10, 7) NOT NULL,
    longitude            DECIMAL(10, 7) NOT NULL,
    radius_meters        INT UNSIGNED   NOT NULL DEFAULT 150,
    is_home              TINYINT(1)     NOT NULL DEFAULT 0,
    notify_on_enter      TINYINT(1)     NOT NULL DEFAULT 1,
    notify_on_exit       TINYINT(1)     NOT NULL DEFAULT 1,
    created_by_device_id INT UNSIGNED   NULL,
    deleted_at           DATETIME       NULL,
    created_at           DATETIME       NOT NULL,
    updated_at           DATETIME       NOT NULL,

    FOREIGN KEY (circle_id) REFERENCES family_circles(id) ON DELETE CASCADE,
    FOREIGN KEY (created_by_device_id) REFERENCES devices(id) ON DELETE SET NULL,
    INDEX idx_saved_places_circle (circle_id, deleted_at)
) ENGINE=InnoDB;

-- ============================================================
-- Table: place_events
-- Named place enter/exit notifications (never continuous GPS trails).
-- ============================================================
CREATE TABLE IF NOT EXISTS place_events (
    id             INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    event_id       VARCHAR(64)  NOT NULL UNIQUE,
    circle_id      INT UNSIGNED NOT NULL,
    device_id      INT UNSIGNED NOT NULL,
    member_name    VARCHAR(64)  NOT NULL,
    place_id       VARCHAR(64)  NOT NULL,
    place_name     VARCHAR(64)  NOT NULL,
    place_category VARCHAR(16)  NOT NULL DEFAULT 'custom',
    event_type     VARCHAR(16)  NOT NULL,
    occurred_at    DATETIME     NOT NULL,
    created_at     DATETIME     NOT NULL,

    FOREIGN KEY (circle_id) REFERENCES family_circles(id) ON DELETE CASCADE,
    FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE,
    INDEX idx_place_events_circle_time (circle_id, occurred_at)
) ENGINE=InnoDB;

-- ============================================================
-- Table: push_tokens
-- Optional FCM device tokens for push alerts.
-- ============================================================
CREATE TABLE IF NOT EXISTS push_tokens (
    device_id  INT UNSIGNED NOT NULL PRIMARY KEY,
    fcm_token  TEXT         NOT NULL,
    platform   VARCHAR(16)  NOT NULL DEFAULT 'android',
    updated_at DATETIME     NOT NULL,

    FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- ============================================================
-- Table: dashboard_circle_pairings
-- Lets a browser dashboard follow a Family Circle via invite code.
-- ============================================================
CREATE TABLE IF NOT EXISTS dashboard_circle_pairings (
    id         INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    session_id INT UNSIGNED NOT NULL,
    circle_id  INT UNSIGNED NOT NULL,
    paired_at  DATETIME     NOT NULL,
    revoked_at DATETIME     NULL,

    UNIQUE KEY uniq_session_circle (session_id, circle_id),
    FOREIGN KEY (session_id) REFERENCES dashboard_sessions(id) ON DELETE CASCADE,
    FOREIGN KEY (circle_id) REFERENCES family_circles(id) ON DELETE CASCADE,
    INDEX idx_dash_circle_session (session_id, revoked_at)
) ENGINE=InnoDB;
