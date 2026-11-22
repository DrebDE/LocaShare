<?php
/**
 * LocaShare - Database Connection & Schema Manager
 *
 * Provides a singleton PDO connection supporting both MySQL/MariaDB and SQLite.
 */

require_once __DIR__ . '/Env.php';
require_once __DIR__ . '/Response.php';
require_once __DIR__ . '/Security.php';

class Database
{
    private static ?PDO $instance = null;
    private static string $activeDriver = '';

    /**
     * Get the PDO database connection.
     */
    public static function getConnection(): PDO
    {
        if (self::$instance !== null) {
            return self::$instance;
        }

        $config = require __DIR__ . '/../config/app.php';
        $db = $config['db'];
        $driver = strtolower((string) ($db['driver'] ?? 'mysql'));
        $driverExplicitlySet = Env::has('LOCASHARE_DB_DRIVER');

        $tz = $config['app']['timezone'] ?? 'UTC';
        date_default_timezone_set($tz);

        try {
            if ($driver === 'sqlite') {
                self::$instance = self::connectSqlite((string) $db['sqlite_path']);
                self::$activeDriver = 'sqlite';
                self::initializeSqliteSchema(self::$instance);
                return self::$instance;
            }

            try {
                self::$instance = self::connectMysql($db);
                self::$activeDriver = 'mysql';
                return self::$instance;
            } catch (PDOException $mysqlException) {
                // If MySQL was not explicitly forced via env, fall back cleanly to SQLite
                if (!$driverExplicitlySet) {
                    self::$instance = self::connectSqlite((string) $db['sqlite_path']);
                    self::$activeDriver = 'sqlite';
                    self::initializeSqliteSchema(self::$instance);
                    return self::$instance;
                }
                throw $mysqlException;
            }
        } catch (PDOException $e) {
            Security::logError('Database connection failed', $e);
            Response::error('Database connection failed.', 500, 'DB_CONNECTION_ERROR');
        }
    }

    /**
     * Return the active PDO driver name ('sqlite' or 'mysql').
     */
    public static function getDriver(): string
    {
        if (self::$instance === null) {
            self::getConnection();
        }
        return self::$activeDriver ?: (string) self::$instance->getAttribute(PDO::ATTR_DRIVER_NAME);
    }

    /**
     * Reset the singleton connection (used by tests when switching databases).
     */
    public static function resetInstance(): void
    {
        self::$instance = null;
        self::$activeDriver = '';
    }

    /**
     * Override the PDO connection directly (used by tests).
     */
    public static function setInstance(?PDO $pdo): void
    {
        self::$instance = $pdo;
        self::$activeDriver = $pdo ? (string) $pdo->getAttribute(PDO::ATTR_DRIVER_NAME) : '';
    }

    /**
     * Initialize database schema on the active connection (SQLite or MySQL).
     */
    public static function initializeSchema(?PDO $pdo = null): void
    {
        $conn = $pdo ?? self::getConnection();
        $driver = strtolower((string) $conn->getAttribute(PDO::ATTR_DRIVER_NAME));
        if ($driver === 'sqlite') {
            self::initializeSqliteSchema($conn);
        } else {
            self::initializeMysqlSchema($conn);
        }
    }

    /**
     * Connect to SQLite via PDO.
     */
    private static function connectSqlite(string $sqlitePath): PDO
    {
        if ($sqlitePath !== ':memory:') {
            $dir = dirname($sqlitePath);
            if (!is_dir($dir)) {
                @mkdir($dir, 0775, true);
            }
        }

        $pdo = new PDO('sqlite:' . $sqlitePath, null, null, [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES   => false,
        ]);

        $pdo->exec('PRAGMA foreign_keys = ON');
        $pdo->exec('PRAGMA busy_timeout = 5000');
        $pdo->exec('PRAGMA journal_mode = WAL');

        return $pdo;
    }

    /**
     * Connect to MySQL/MariaDB via PDO.
     */
    private static function connectMysql(array $db): PDO
    {
        $dsn = sprintf(
            'mysql:host=%s;port=%d;dbname=%s;charset=%s',
            $db['host'],
            (int) $db['port'],
            $db['name'],
            $db['charset']
        );

        return new PDO($dsn, $db['user'], $db['password'], [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES   => false,
        ]);
    }

    /**
     * Ensure all required tables exist in SQLite.
     */
    public static function initializeSqliteSchema(PDO $pdo): void
    {
        $statements = [
            "CREATE TABLE IF NOT EXISTS devices (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                device_id       TEXT NOT NULL UNIQUE,
                device_name     TEXT NOT NULL DEFAULT 'Android Phone',
                token_hash      TEXT NOT NULL,
                registered_at    TEXT NOT NULL,
                unregistered_at TEXT NULL,
                updated_at      TEXT NOT NULL
            )",
            "CREATE INDEX IF NOT EXISTS idx_devices_active ON devices (unregistered_at, device_id)",
            "CREATE TABLE IF NOT EXISTS device_status (
                id                   INTEGER PRIMARY KEY AUTOINCREMENT,
                device_id            INTEGER NOT NULL UNIQUE,
                sharing_enabled      INTEGER NOT NULL DEFAULT 0,
                status_state         TEXT NOT NULL DEFAULT 'registered',
                presence_mode        TEXT NOT NULL DEFAULT 'unknown',
                current_place_id     TEXT NULL,
                current_place_name   TEXT NULL,
                home_privacy_masked  INTEGER NOT NULL DEFAULT 0,
                smart_home_mode      INTEGER NOT NULL DEFAULT 1,
                speed_mps            REAL NULL,
                battery_percentage   INTEGER NULL,
                is_charging          INTEGER NULL,
                network_status       TEXT NULL DEFAULT 'unknown',
                last_latitude        REAL NULL,
                last_longitude       REAL NULL,
                last_accuracy        REAL NULL,
                location_recorded_at TEXT NULL,
                location_received_at TEXT NULL,
                last_heartbeat_at    TEXT NULL,
                updated_at           TEXT NOT NULL,
                FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE
            )",
            "CREATE INDEX IF NOT EXISTS idx_device_status_device ON device_status (device_id)",
            "CREATE TABLE IF NOT EXISTS pairing_codes (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                device_id   INTEGER NOT NULL,
                code_hash   TEXT NOT NULL UNIQUE,
                expires_at  TEXT NOT NULL,
                used_at     TEXT NULL,
                revoked_at  TEXT NULL,
                created_at  TEXT NOT NULL,
                FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE
            )",
            "CREATE INDEX IF NOT EXISTS idx_pairing_device_active ON pairing_codes (device_id, expires_at, used_at, revoked_at)",
            "CREATE TABLE IF NOT EXISTS dashboard_sessions (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                session_hash TEXT NOT NULL UNIQUE,
                csrf_token   TEXT NOT NULL,
                label        TEXT NOT NULL DEFAULT 'Laptop Browser',
                created_at   TEXT NOT NULL,
                last_seen_at TEXT NOT NULL,
                expires_at   TEXT NOT NULL
            )",
            "CREATE INDEX IF NOT EXISTS idx_sessions_expiry ON dashboard_sessions (expires_at)",
            "CREATE TABLE IF NOT EXISTS dashboard_device_pairings (
                id                         INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id                 INTEGER NOT NULL,
                device_id                  INTEGER NOT NULL,
                paired_at                  TEXT NOT NULL,
                revoked_at                 TEXT NULL,
                revoked_by                 TEXT NULL,
                revocation_acknowledged_at TEXT NULL,
                UNIQUE (session_id, device_id),
                FOREIGN KEY (session_id) REFERENCES dashboard_sessions(id) ON DELETE CASCADE,
                FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE
            )",
            "CREATE INDEX IF NOT EXISTS idx_pairings_session_active ON dashboard_device_pairings (session_id, revoked_at)",
            "CREATE INDEX IF NOT EXISTS idx_pairings_device_active ON dashboard_device_pairings (device_id, revoked_at)",
            "CREATE TABLE IF NOT EXISTS family_circles (
                id                   INTEGER PRIMARY KEY AUTOINCREMENT,
                circle_id            TEXT NOT NULL UNIQUE,
                name                 TEXT NOT NULL,
                invite_code          TEXT NOT NULL,
                invite_code_hash     TEXT NOT NULL UNIQUE,
                created_by_device_id INTEGER NOT NULL,
                created_at           TEXT NOT NULL,
                updated_at           TEXT NOT NULL,
                FOREIGN KEY (created_by_device_id) REFERENCES devices(id) ON DELETE CASCADE
            )",
            "CREATE TABLE IF NOT EXISTS circle_members (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                circle_id    INTEGER NOT NULL,
                device_id    INTEGER NOT NULL,
                member_name  TEXT NOT NULL,
                role         TEXT NOT NULL DEFAULT 'member',
                avatar_color TEXT NOT NULL DEFAULT '#0EA5E9',
                joined_at    TEXT NOT NULL,
                left_at      TEXT NULL,
                UNIQUE (circle_id, device_id),
                FOREIGN KEY (circle_id) REFERENCES family_circles(id) ON DELETE CASCADE,
                FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE
            )",
            "CREATE INDEX IF NOT EXISTS idx_circle_members_active ON circle_members (device_id, left_at)",
            "CREATE INDEX IF NOT EXISTS idx_circle_members_circle ON circle_members (circle_id, left_at)",
            "CREATE TABLE IF NOT EXISTS saved_places (
                id                   INTEGER PRIMARY KEY AUTOINCREMENT,
                place_id             TEXT NOT NULL UNIQUE,
                circle_id            INTEGER NOT NULL,
                name                 TEXT NOT NULL,
                category             TEXT NOT NULL DEFAULT 'custom',
                latitude             REAL NOT NULL,
                longitude            REAL NOT NULL,
                radius_meters        INTEGER NOT NULL DEFAULT 150,
                is_home              INTEGER NOT NULL DEFAULT 0,
                notify_on_enter      INTEGER NOT NULL DEFAULT 1,
                notify_on_exit       INTEGER NOT NULL DEFAULT 1,
                created_by_device_id INTEGER NULL,
                deleted_at           TEXT NULL,
                created_at           TEXT NOT NULL,
                updated_at           TEXT NOT NULL,
                FOREIGN KEY (circle_id) REFERENCES family_circles(id) ON DELETE CASCADE,
                FOREIGN KEY (created_by_device_id) REFERENCES devices(id) ON DELETE SET NULL
            )",
            "CREATE INDEX IF NOT EXISTS idx_saved_places_circle ON saved_places (circle_id, deleted_at)",
            "CREATE TABLE IF NOT EXISTS place_events (
                id             INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id       TEXT NOT NULL UNIQUE,
                circle_id      INTEGER NOT NULL,
                device_id      INTEGER NOT NULL,
                member_name    TEXT NOT NULL,
                place_id       TEXT NOT NULL,
                place_name     TEXT NOT NULL,
                place_category TEXT NOT NULL DEFAULT 'custom',
                event_type     TEXT NOT NULL,
                occurred_at    TEXT NOT NULL,
                created_at     TEXT NOT NULL,
                FOREIGN KEY (circle_id) REFERENCES family_circles(id) ON DELETE CASCADE,
                FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE
            )",
            "CREATE INDEX IF NOT EXISTS idx_place_events_circle_time ON place_events (circle_id, occurred_at)",
            "CREATE TABLE IF NOT EXISTS push_tokens (
                device_id  INTEGER PRIMARY KEY,
                fcm_token  TEXT NOT NULL,
                platform   TEXT NOT NULL DEFAULT 'android',
                updated_at TEXT NOT NULL,
                FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE
            )",
            "CREATE TABLE IF NOT EXISTS dashboard_circle_pairings (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id INTEGER NOT NULL,
                circle_id  INTEGER NOT NULL,
                paired_at  TEXT NOT NULL,
                revoked_at TEXT NULL,
                UNIQUE (session_id, circle_id),
                FOREIGN KEY (session_id) REFERENCES dashboard_sessions(id) ON DELETE CASCADE,
                FOREIGN KEY (circle_id) REFERENCES family_circles(id) ON DELETE CASCADE
            )",
            "CREATE INDEX IF NOT EXISTS idx_dash_circle_session ON dashboard_circle_pairings (session_id, revoked_at)",
        ];

        foreach ($statements as $sql) {
            $pdo->exec($sql);
        }

        // Non-destructive migration for existing SQLite databases missing new device_status columns
        $cols = $pdo->query("PRAGMA table_info(device_status)")->fetchAll();
        $existingCols = array_column($cols, 'name');
        $migrations = [
            'presence_mode'       => "ALTER TABLE device_status ADD COLUMN presence_mode TEXT NOT NULL DEFAULT 'unknown'",
            'current_place_id'    => "ALTER TABLE device_status ADD COLUMN current_place_id TEXT NULL",
            'current_place_name'  => "ALTER TABLE device_status ADD COLUMN current_place_name TEXT NULL",
            'home_privacy_masked' => "ALTER TABLE device_status ADD COLUMN home_privacy_masked INTEGER NOT NULL DEFAULT 0",
            'smart_home_mode'     => "ALTER TABLE device_status ADD COLUMN smart_home_mode INTEGER NOT NULL DEFAULT 1",
            'speed_mps'           => "ALTER TABLE device_status ADD COLUMN speed_mps REAL NULL",
        ];
        foreach ($migrations as $col => $alterSql) {
            if (!in_array($col, $existingCols, true)) {
                $pdo->exec($alterSql);
            }
        }
    }

    /**
     * Initialize schema on MySQL/MariaDB from backend/database/schema.sql.
     */
    public static function initializeMysqlSchema(PDO $pdo): void
    {
        $schemaPath = dirname(__DIR__) . DIRECTORY_SEPARATOR . 'database' . DIRECTORY_SEPARATOR . 'schema.sql';
        if (!is_file($schemaPath)) {
            throw new RuntimeException('Missing backend/database/schema.sql');
        }
        $sql = (string) file_get_contents($schemaPath);
        // Strip SQL comments and execute individual statements
        $lines = explode("\n", $sql);
        $cleanLines = [];
        foreach ($lines as $line) {
            $trimmed = trim($line);
            if ($trimmed === '' || str_starts_with($trimmed, '--')) {
                continue;
            }
            $cleanLines[] = $line;
        }
        $cleanSql = implode("\n", $cleanLines);
        $statements = array_filter(array_map('trim', explode(';', $cleanSql)));
        foreach ($statements as $stmt) {
            if (stripos($stmt, 'CREATE DATABASE') === 0 || stripos($stmt, 'USE ') === 0) {
                continue;
            }
            $pdo->exec($stmt);
        }
    }
}
