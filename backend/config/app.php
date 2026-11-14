<?php
/**
 * LocaShare - Application Configuration
 *
 * Reads deployment configuration from environment variables (or backend/.env).
 * Never commit real credentials or secrets to version control.
 */

require_once __DIR__ . '/../includes/Env.php';

Env::load();

$sqliteDefaultPath = dirname(__DIR__) . DIRECTORY_SEPARATOR . 'database' . DIRECTORY_SEPARATOR . 'locashare.sqlite';
$sqliteConfigured = Env::get('LOCASHARE_DB_SQLITE_PATH', '');
if ($sqliteConfigured !== '' && $sqliteConfigured !== ':memory:' && !preg_match('/^([a-zA-Z]:[\\\\\\/]|[\\\\\\/])/', $sqliteConfigured)) {
    // Resolve relative paths from repository root
    $sqliteConfigured = dirname(__DIR__, 2) . DIRECTORY_SEPARATOR . str_replace(['/', '\\'], DIRECTORY_SEPARATOR, $sqliteConfigured);
}

return [
    // ── Database ────────────────────────────────────────────
    'db' => [
        'driver'      => strtolower((string) Env::get('LOCASHARE_DB_DRIVER', 'mysql')),
        'host'        => (string) Env::get('LOCASHARE_DB_HOST', '127.0.0.1'),
        'port'        => Env::int('LOCASHARE_DB_PORT', 3306),
        'name'        => (string) Env::get('LOCASHARE_DB_NAME', 'locashare'),
        'user'        => (string) Env::get('LOCASHARE_DB_USER', 'root'),
        'password'    => (string) Env::get('LOCASHARE_DB_PASSWORD', ''),
        'charset'     => (string) Env::get('LOCASHARE_DB_CHARSET', 'utf8mb4'),
        'sqlite_path' => $sqliteConfigured !== '' ? $sqliteConfigured : $sqliteDefaultPath,
    ],

    // ── Security & Pairing ──────────────────────────────────
    'security' => [
        'pairing_code_ttl_seconds' => max(30, Env::int('LOCASHARE_PAIRING_TTL_SECONDS', 300)),
        'pairing_code_length'      => max(8, min(12, Env::int('LOCASHARE_PAIRING_CODE_LENGTH', 8))),
        'session_ttl_seconds'      => max(300, Env::int('LOCASHARE_SESSION_TTL_SECONDS', 2592000)),
        'session_cookie_name'      => 'locashare_session',
        'cookie_secure'            => strtolower((string) Env::get('LOCASHARE_COOKIE_SECURE', 'auto')),
        'cookie_samesite'          => (string) Env::get('LOCASHARE_COOKIE_SAMESITE', 'Strict'),
        'max_payload_bytes'        => max(1024, Env::int('LOCASHARE_MAX_PAYLOAD_BYTES', 16384)),
        'allowed_origins'          => Env::csv('LOCASHARE_ALLOWED_ORIGINS'),
    ],

    // ── Rate Limiting ───────────────────────────────────────
    'rate_limit' => [
        'storage_dir' => (string) Env::get('LOCASHARE_RATE_LIMIT_DIR', sys_get_temp_dir()),
        'api' => [
            'max_requests'   => Env::int('LOCASHARE_RATE_LIMIT_API_MAX', 120),
            'window_seconds' => Env::int('LOCASHARE_RATE_LIMIT_API_WINDOW', 60),
        ],
        'register' => [
            'max_requests'   => Env::int('LOCASHARE_RATE_LIMIT_REGISTER_MAX', 10),
            'window_seconds' => Env::int('LOCASHARE_RATE_LIMIT_REGISTER_WINDOW', 300),
        ],
        'pair' => [
            'max_requests'   => Env::int('LOCASHARE_RATE_LIMIT_PAIR_MAX', 10),
            'window_seconds' => Env::int('LOCASHARE_RATE_LIMIT_PAIR_WINDOW', 300),
        ],
    ],

    // ── Status Freshness Thresholds ─────────────────────────
    'status' => [
        'online_threshold_seconds' => max(15, Env::int('LOCASHARE_ONLINE_THRESHOLD_SECONDS', 90)),
        'location_stale_seconds'   => max(30, Env::int('LOCASHARE_LOCATION_STALE_SECONDS', 180)),
    ],

    // ── Data Retention (Latest-Only by Default) ─────────────
    'retention' => [
        'route_history_enabled' => false,
    ],

    // ── Dashboard ───────────────────────────────────────────
    'dashboard' => [
        'poll_interval_ms' => max(2000, Env::int('LOCASHARE_DASHBOARD_POLL_MS', 10000)),
    ],

    // ── Application ─────────────────────────────────────────
    'app' => [
        'name'     => 'LocaShare',
        'version'  => '2.0.0',
        'debug'    => Env::bool('LOCASHARE_APP_DEBUG', false),
        'timezone' => (string) Env::get('LOCASHARE_TIMEZONE', 'UTC'),
        'base_url' => (string) Env::get('LOCASHARE_BASE_URL', ''),
    ],
];
