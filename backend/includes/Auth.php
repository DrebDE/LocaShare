<?php
/**
 * LocaShare - Authentication & Session Middleware
 *
 * Enforces strict access control:
 *   1. Phones authenticate via per-device Bearer token and can only modify their own device.
 *   2. Laptop dashboards authenticate via HttpOnly, SameSite, Secure session cookies
 *      plus CSRF tokens on state-changing requests, and can only access devices paired to their session.
 */

require_once __DIR__ . '/Database.php';
require_once __DIR__ . '/Response.php';
require_once __DIR__ . '/Security.php';

class Auth
{
    /**
     * Authenticate an incoming phone API request and return the device record.
     *
     * @param array|null $parsedBody Optional already-parsed JSON payload.
     * @return array{id: int, device_id: string, device_name: string}
     */
    public static function requireDevice(?array $parsedBody = null): array
    {
        $token = self::extractBearerToken();
        if ($token === '') {
            Response::error('Missing authentication token.', 401, 'MISSING_TOKEN');
        }

        $deviceId = self::extractDeviceId($parsedBody);
        if ($deviceId === '' || !Security::isValidDeviceId($deviceId)) {
            Response::error('Missing or invalid device identifier.', 401, 'INVALID_DEVICE_ID');
        }

        $db = Database::getConnection();
        $stmt = $db->prepare('
            SELECT id, device_id, device_name, token_hash, unregistered_at
            FROM devices
            WHERE device_id = ?
            LIMIT 1
        ');
        $stmt->execute([$deviceId]);
        $device = $stmt->fetch();

        if (!$device) {
            Response::error('Unknown device.', 401, 'UNKNOWN_DEVICE');
        }

        if ($device['unregistered_at'] !== null) {
            Response::error('This device has been unregistered.', 401, 'DEVICE_UNREGISTERED');
        }

        if (!Security::verifyToken($token, (string) $device['token_hash'])) {
            Response::error('Invalid authentication token.', 401, 'INVALID_TOKEN');
        }

        $authenticated = [
            'id'          => (int) $device['id'],
            'device_id'   => (string) $device['device_id'],
            'device_name' => (string) $device['device_name'],
        ];

        $_REQUEST['_authenticated_device_db_id'] = $authenticated['id'];
        $_REQUEST['_authenticated_device_id']    = $authenticated['device_id'];

        return $authenticated;
    }

    /**
     * Backwards-compatible alias for requireDevice().
     */
    public static function requireToken(?array $parsedBody = null): array
    {
        return self::requireDevice($parsedBody);
    }

    /**
     * Look up an existing valid dashboard session from the request cookie, or return null.
     *
     * @return array{id: int, csrf_token: string, label: string, created_at: string, expires_at: string}|null
     */
    public static function getOptionalDashboardSession(): ?array
    {
        $config = require __DIR__ . '/../config/app.php';
        $cookieName = (string) ($config['security']['session_cookie_name'] ?? 'locashare_session');

        $rawToken = self::extractCookieToken($cookieName);
        if ($rawToken === '' || strlen($rawToken) < 32) {
            return null;
        }

        $sessionHash = Security::hashToken($rawToken);
        $db = Database::getConnection();

        $stmt = $db->prepare('
            SELECT id, session_hash, csrf_token, label, created_at, last_seen_at, expires_at
            FROM dashboard_sessions
            WHERE session_hash = ?
            LIMIT 1
        ');
        $stmt->execute([$sessionHash]);
        $session = $stmt->fetch();

        if (!$session) {
            return null;
        }

        $expiresTs = strtotime((string) $session['expires_at'] . ' UTC');
        if ($expiresTs === false || $expiresTs <= time()) {
            return null;
        }

        $nowUtc = gmdate('Y-m-d H:i:s');
        $upd = $db->prepare('UPDATE dashboard_sessions SET last_seen_at = ? WHERE id = ?');
        $upd->execute([$nowUtc, (int) $session['id']]);

        return [
            'id'         => (int) $session['id'],
            'csrf_token' => (string) $session['csrf_token'],
            'label'      => (string) $session['label'],
            'created_at' => (string) $session['created_at'],
            'expires_at' => (string) $session['expires_at'],
        ];
    }

    /**
     * Retrieve the current valid dashboard session or create a new one and set its HttpOnly cookie.
     *
     * @return array{id: int, csrf_token: string, label: string, created_at: string, expires_at: string, raw_token?: string}
     */
    public static function getOrCreateDashboardSession(): array
    {
        $existing = self::getOptionalDashboardSession();
        if ($existing !== null) {
            return $existing;
        }

        $config = require __DIR__ . '/../config/app.php';
        $sec = $config['security'];
        $cookieName = (string) ($sec['session_cookie_name'] ?? 'locashare_session');
        $ttlSeconds = max(300, (int) ($sec['session_ttl_seconds'] ?? 2592000));

        $rawToken = Security::generateToken(32);
        $sessionHash = Security::hashToken($rawToken);
        $csrfToken = Security::generateToken(32);

        $now = time();
        $nowUtc = gmdate('Y-m-d H:i:s', $now);
        $expiresAtUtc = gmdate('Y-m-d H:i:s', $now + $ttlSeconds);

        $db = Database::getConnection();
        $stmt = $db->prepare('
            INSERT INTO dashboard_sessions (session_hash, csrf_token, label, created_at, last_seen_at, expires_at)
            VALUES (?, ?, ?, ?, ?, ?)
        ');
        $stmt->execute([
            $sessionHash,
            $csrfToken,
            'Laptop Browser',
            $nowUtc,
            $nowUtc,
            $expiresAtUtc,
        ]);

        $sessionId = (int) $db->lastInsertId();

        self::setSessionCookie($cookieName, $rawToken, $now + $ttlSeconds, $sec);
        $_COOKIE[$cookieName] = $rawToken;

        return [
            'id'         => $sessionId,
            'csrf_token' => $csrfToken,
            'label'      => 'Laptop Browser',
            'created_at' => $nowUtc,
            'expires_at' => $expiresAtUtc,
            'raw_token'  => $rawToken,
        ];
    }

    /**
     * Require a valid existing dashboard session (and optionally verify CSRF token).
     *
     * @param bool       $requireCsrf Whether to require a valid CSRF token.
     * @param array|null $parsedBody  Optional parsed JSON request body.
     * @return array{id: int, csrf_token: string, label: string, created_at: string, expires_at: string}
     */
    public static function requireDashboardSession(bool $requireCsrf = false, ?array $parsedBody = null): array
    {
        $session = self::getOptionalDashboardSession();
        if ($session === null) {
            Response::error(
                'Valid dashboard session required. Pair a device to establish dashboard access.',
                401,
                'SESSION_REQUIRED'
            );
        }

        if ($requireCsrf) {
            self::verifyCsrfToken($session['csrf_token'], $parsedBody);
        }

        return $session;
    }

    /**
     * Verify the CSRF token from header or JSON payload against the session's csrf_token.
     */
    public static function verifyCsrfToken(string $expectedCsrf, ?array $parsedBody = null): void
    {
        $provided = $_SERVER['HTTP_X_CSRF_TOKEN'] ?? '';
        if ($provided === '' && is_array($parsedBody) && isset($parsedBody['csrf_token']) && is_string($parsedBody['csrf_token'])) {
            $provided = $parsedBody['csrf_token'];
        }
        if ($provided === '' && isset($_POST['csrf_token']) && is_string($_POST['csrf_token'])) {
            $provided = $_POST['csrf_token'];
        }

        $provided = trim($provided);
        if ($provided === '' || !hash_equals($expectedCsrf, $provided)) {
            Response::error('Invalid or missing CSRF token.', 403, 'INVALID_CSRF_TOKEN');
        }
    }

    /**
     * Set the HttpOnly, SameSite, Secure session cookie.
     */
    private static function setSessionCookie(string $name, string $value, int $expiresEpoch, array $secConfig): void
    {
        if (headers_sent()) {
            return;
        }

        $isHttps = (!empty($_SERVER['HTTPS']) && strtolower((string) $_SERVER['HTTPS']) !== 'off')
            || (($_SERVER['SERVER_PORT'] ?? null) == 443)
            || (strtolower((string) ($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '')) === 'https');

        $secureSetting = strtolower((string) ($secConfig['cookie_secure'] ?? 'auto'));
        $secure = match ($secureSetting) {
            'true', '1', 'always' => true,
            'false', '0', 'never' => false,
            default               => $isHttps,
        };

        $sameSite = (string) ($secConfig['cookie_samesite'] ?? 'Strict');
        if (!in_array($sameSite, ['Strict', 'Lax', 'None'], true)) {
            $sameSite = 'Strict';
        }

        setcookie($name, $value, [
            'expires'  => $expiresEpoch,
            'path'     => '/',
            'secure'   => $secure,
            'httponly' => true,
            'samesite' => $sameSite,
        ]);
    }

    /**
     * Extract Bearer token from Authorization headers.
     */
    private static function extractBearerToken(): string
    {
        $authHeader = $_SERVER['HTTP_AUTHORIZATION']
            ?? $_SERVER['REDIRECT_HTTP_AUTHORIZATION']
            ?? '';

        if ($authHeader === '' && function_exists('getallheaders')) {
            $headers = getallheaders();
            if (is_array($headers)) {
                foreach ($headers as $k => $v) {
                    if (strcasecmp((string) $k, 'Authorization') === 0 && is_string($v)) {
                        $authHeader = $v;
                        break;
                    }
                }
            }
        }

        if (preg_match('/^Bearer\s+(.+)$/i', $authHeader, $matches)) {
            return trim($matches[1]);
        }

        return '';
    }

    /**
     * Extract device_id from parsed JSON body, raw JSON body, query string, or X-Device-Id header.
     * Rejects ambiguous requests that supply conflicting non-empty device_id values.
     */
    private static function extractDeviceId(?array $parsedBody = null): string
    {
        $candidates = [];

        if (is_array($parsedBody) && !empty($parsedBody['device_id']) && is_string($parsedBody['device_id'])) {
            $candidates[] = trim($parsedBody['device_id']);
        } else {
            $raw = Security::getRawInput();
            if ($raw !== '') {
                $decoded = json_decode($raw, true);
                if (is_array($decoded) && !empty($decoded['device_id']) && is_string($decoded['device_id'])) {
                    $candidates[] = trim($decoded['device_id']);
                }
            }
        }

        if (!empty($_GET['device_id']) && is_string($_GET['device_id'])) {
            $candidates[] = trim($_GET['device_id']);
        }

        if (!empty($_POST['device_id']) && is_string($_POST['device_id'])) {
            $candidates[] = trim($_POST['device_id']);
        }

        if (!empty($_SERVER['HTTP_X_DEVICE_ID']) && is_string($_SERVER['HTTP_X_DEVICE_ID'])) {
            $candidates[] = trim($_SERVER['HTTP_X_DEVICE_ID']);
        }

        $unique = array_values(array_unique(array_filter($candidates, static fn(string $v): bool => $v !== '')));
        if (count($unique) > 1) {
            Response::error('Conflicting device_id values supplied.', 403, 'FORBIDDEN_DEVICE');
        }

        return $unique[0] ?? '';
    }

    /**
     * Extract session cookie token from $_COOKIE or raw HTTP_COOKIE header.
     */
    private static function extractCookieToken(string $cookieName): string
    {
        if (!empty($_COOKIE[$cookieName]) && is_string($_COOKIE[$cookieName])) {
            return trim($_COOKIE[$cookieName]);
        }

        $cookieHeader = $_SERVER['HTTP_COOKIE'] ?? '';
        if ($cookieHeader !== '') {
            $parts = explode(';', $cookieHeader);
            foreach ($parts as $part) {
                $kv = explode('=', trim($part), 2);
                if (count($kv) === 2 && trim($kv[0]) === $cookieName) {
                    return trim(urldecode($kv[1]));
                }
            }
        }

        return '';
    }
}
