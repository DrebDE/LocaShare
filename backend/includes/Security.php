<?php
/**
 * LocaShare - Security & Validation Utilities
 *
 * Provides cryptographically secure token/code generation, request body
 * size validation, strict coordinate/timestamp validation, and redacted logging.
 * Never logs pairing codes, access tokens, or precise coordinates.
 */

class Security
{
    /**
     * Unambiguous uppercase alphanumeric alphabet for human-entered pairing codes.
     */
    private const PAIRING_ALPHABET = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

    /**
     * Allowed operational states reported by a phone.
     */
    public const VALID_STATUS_STATES = [
        'registered',
        'waiting_for_pairing',
        'sharing',
        'paused',
        'no_gps_fix',
        'offline',
        'permission_missing',
        'unregistered',
    ];

    private static ?string $cachedRawInput = null;
    private static ?string $testRawInputOverride = null;

    /**
     * Set raw request body override for in-process automated tests.
     */
    public static function setRawInputOverride(?string $raw): void
    {
        self::$testRawInputOverride = $raw;
        self::$cachedRawInput = null;
    }

    /**
     * Read the raw request body once (respecting test overrides).
     */
    public static function getRawInput(): string
    {
        if (self::$testRawInputOverride !== null) {
            return self::$testRawInputOverride;
        }
        if (self::$cachedRawInput === null) {
            $raw = file_get_contents('php://input');
            self::$cachedRawInput = is_string($raw) ? $raw : '';
        }
        return self::$cachedRawInput;
    }

    /**
     * Read and validate JSON request body against max_payload_bytes.
     *
     * @param bool $allowEmpty Whether an empty body is allowed (returns []).
     * @return array Parsed associative array.
     */
    public static function readJsonBody(bool $allowEmpty = false): array
    {
        $config = require __DIR__ . '/../config/app.php';
        $maxBytes = (int) ($config['security']['max_payload_bytes'] ?? 16384);

        $contentLength = isset($_SERVER['CONTENT_LENGTH']) ? (int) $_SERVER['CONTENT_LENGTH'] : 0;
        if ($contentLength > $maxBytes) {
            Response::error('Request payload exceeds maximum allowed size.', 413, 'PAYLOAD_TOO_LARGE');
        }

        $raw = self::getRawInput();
        if (strlen($raw) > $maxBytes) {
            Response::error('Request payload exceeds maximum allowed size.', 413, 'PAYLOAD_TOO_LARGE');
        }

        if (trim($raw) === '') {
            if ($allowEmpty) {
                return [];
            }
            Response::error('Request body is required.', 400, 'EMPTY_PAYLOAD');
        }

        $decoded = json_decode($raw, true);
        if (!is_array($decoded) || json_last_error() !== JSON_ERROR_NONE) {
            Response::error('Invalid JSON payload.', 400, 'INVALID_JSON');
        }

        return $decoded;
    }

    /**
     * Generate a unique public device identifier (e.g., dev_ + 24 hex chars).
     */
    public static function generateDeviceId(): string
    {
        return 'dev_' . bin2hex(random_bytes(12));
    }

    /**
     * Generate a high-entropy bearer token (64 hex chars = 256 bits).
     */
    public static function generateToken(int $bytes = 32): string
    {
        return bin2hex(random_bytes(max(16, $bytes)));
    }

    /**
     * Generate a cryptographically random one-time pairing code.
     *
     * @param int $length Number of alphanumeric characters (8..12).
     * @return array{raw: string, formatted: string, hash: string}
     */
    public static function generatePairingCode(int $length = 8): array
    {
        $length = max(8, min(12, $length));
        $alphabet = self::PAIRING_ALPHABET;
        $maxIndex = strlen($alphabet) - 1;

        $raw = '';
        for ($i = 0; $i < $length; $i++) {
            $raw .= $alphabet[random_int(0, $maxIndex)];
        }

        $half = (int) floor($length / 2);
        $formatted = substr($raw, 0, $half) . '-' . substr($raw, $half);

        return [
            'raw'       => $raw,
            'formatted' => $formatted,
            'hash'      => self::hashToken($raw),
        ];
    }

    /**
     * Normalize a user-submitted pairing code or QR payload.
     * Supports raw codes ("ABCD-2345") and QR URIs ("locashare://pair?code=ABCD-2345").
     */
    public static function normalizePairingCode(string $input): string
    {
        $trimmed = trim($input);

        // Extract code parameter if a QR URI or URL was scanned
        if (stripos($trimmed, 'code=') !== false) {
            $queryPos = strpos($trimmed, '?');
            $queryStr = $queryPos !== false ? substr($trimmed, $queryPos + 1) : $trimmed;
            parse_str($queryStr, $params);
            if (!empty($params['code']) && is_string($params['code'])) {
                $trimmed = $params['code'];
            }
        }

        $normalized = strtoupper((string) preg_replace('/[\s\-_]+/', '', $trimmed));
        return $normalized;
    }

    /**
     * Validate a normalized pairing code format.
     */
    public static function isValidPairingCodeFormat(string $normalizedCode): bool
    {
        return (bool) preg_match('/^[A-Z0-9]{6,16}$/', $normalizedCode);
    }

    /**
     * Format a normalized pairing code with a middle hyphen for display.
     */
    public static function formatPairingCode(string $normalizedCode): string
    {
        $clean = self::normalizePairingCode($normalizedCode);
        $len = strlen($clean);
        if ($len < 4) {
            return $clean;
        }
        $half = (int) floor($len / 2);
        return substr($clean, 0, $half) . '-' . substr($clean, $half);
    }

    /**
     * Compute SHA-256 hex digest of a secret token or pairing code.
     */
    public static function hashToken(string $secret): string
    {
        return hash('sha256', $secret);
    }

    /**
     * Verify a secret token against a stored SHA-256 hex hash or bcrypt/argon2 hash.
     */
    public static function verifyToken(string $token, string $storedHash): bool
    {
        if ($token === '' || $storedHash === '') {
            return false;
        }

        // SHA-256 hex hash (64 hex chars)
        if (strlen($storedHash) === 64 && ctype_xdigit($storedHash)) {
            $computed = self::hashToken($token);
            return hash_equals(strtolower($storedHash), strtolower($computed));
        }

        // Legacy password_hash support
        if (str_starts_with($storedHash, '$')) {
            return password_verify($token, $storedHash);
        }

        return false;
    }

    /**
     * Validate device_id format.
     */
    public static function isValidDeviceId(mixed $deviceId): bool
    {
        if (!is_string($deviceId)) {
            return false;
        }
        $trimmed = trim($deviceId);
        return (bool) preg_match('/^[a-zA-Z0-9_\-]{4,64}$/', $trimmed);
    }

    /**
     * Sanitize and validate a human-readable device name.
     */
    public static function sanitizeDeviceName(mixed $name, string $default = 'Android Phone'): string
    {
        if (!is_string($name)) {
            return $default;
        }
        // Strip control characters and HTML tags
        $clean = trim(strip_tags((string) preg_replace('/[\x00-\x1F\x7F]+/', '', $name)));
        if ($clean === '') {
            return $default;
        }
        if (function_exists('mb_substr')) {
            return mb_substr($clean, 0, 64, 'UTF-8');
        }
        return substr($clean, 0, 64);
    }

    /**
     * Validate latitude and longitude coordinates.
     *
     * @return array{valid: bool, error?: string, latitude?: float, longitude?: float}
     */
    public static function validateCoordinates(mixed $latitude, mixed $longitude): array
    {
        if ($latitude === null || $longitude === null || $latitude === '' || $longitude === '') {
            return ['valid' => false, 'error' => 'Latitude and longitude are required.'];
        }
        if (is_bool($latitude) || is_bool($longitude) || !is_numeric($latitude) || !is_numeric($longitude)) {
            return ['valid' => false, 'error' => 'Latitude and longitude must be numeric values.'];
        }

        $lat = (float) $latitude;
        $lng = (float) $longitude;

        if (!is_finite($lat) || !is_finite($lng)) {
            return ['valid' => false, 'error' => 'Coordinates must be finite numbers.'];
        }
        if ($lat < -90.0 || $lat > 90.0) {
            return ['valid' => false, 'error' => 'Invalid latitude. Must be between -90 and 90.'];
        }
        if ($lng < -180.0 || $lng > 180.0) {
            return ['valid' => false, 'error' => 'Invalid longitude. Must be between -180 and 180.'];
        }

        return [
            'valid'     => true,
            'latitude'  => round($lat, 7),
            'longitude' => round($lng, 7),
        ];
    }

    /**
     * Validate optional accuracy in meters.
     *
     * @return array{valid: bool, error?: string, accuracy?: ?float}
     */
    public static function validateAccuracy(mixed $accuracy): array
    {
        if ($accuracy === null || $accuracy === '') {
            return ['valid' => true, 'accuracy' => null];
        }
        if (is_bool($accuracy) || !is_numeric($accuracy)) {
            return ['valid' => false, 'error' => 'Accuracy must be a numeric value in meters.'];
        }
        $acc = (float) $accuracy;
        if (!is_finite($acc) || $acc < 0.0 || $acc > 100000.0) {
            return ['valid' => false, 'error' => 'Accuracy must be between 0 and 100000 meters.'];
        }
        return ['valid' => true, 'accuracy' => round($acc, 2)];
    }

    /**
     * Validate and normalize a location-fix timestamp to UTC 'Y-m-d H:i:s'.
     * Rejects malformed timestamps, timestamps more than 5 minutes in the future,
     * or timestamps older than 30 days.
     *
     * @return array{valid: bool, error?: string, utc_datetime?: string, timestamp?: int}
     */
    public static function validateTimestamp(mixed $timestamp): array
    {
        $now = time();

        if ($timestamp === null || $timestamp === '') {
            return [
                'valid'        => true,
                'utc_datetime' => gmdate('Y-m-d H:i:s', $now),
                'timestamp'    => $now,
            ];
        }

        $epoch = null;

        if (is_int($timestamp) || is_float($timestamp) || (is_string($timestamp) && preg_match('/^\d{10,13}$/', trim($timestamp)))) {
            $num = (float) $timestamp;
            // Convert milliseconds to seconds if > 1e11
            $epoch = $num > 100000000000 ? (int) round($num / 1000) : (int) round($num);
        } elseif (is_string($timestamp)) {
            try {
                $dt = new DateTimeImmutable(trim($timestamp), new DateTimeZone('UTC'));
                $epoch = $dt->getTimestamp();
            } catch (Exception) {
                return ['valid' => false, 'error' => 'Invalid timestamp format. Use ISO-8601 or epoch milliseconds.'];
            }
        } else {
            return ['valid' => false, 'error' => 'Invalid timestamp type.'];
        }

        if ($epoch > ($now + 300)) {
            return ['valid' => false, 'error' => 'Timestamp cannot be in the future.'];
        }

        if ($epoch < ($now - (86400 * 30))) {
            return ['valid' => false, 'error' => 'Timestamp is too old (exceeds 30-day maximum age).'];
        }

        return [
            'valid'        => true,
            'utc_datetime' => gmdate('Y-m-d H:i:s', $epoch),
            'timestamp'    => $epoch,
        ];
    }

    /**
     * Validate device operational status state.
     */
    public static function validateStatusState(mixed $state, string $default = 'registered'): string
    {
        if (!is_string($state)) {
            return $default;
        }
        $normalized = strtolower(trim($state));
        if (in_array($normalized, self::VALID_STATUS_STATES, true)) {
            return $normalized;
        }
        return $default;
    }

    /**
     * Redact sensitive values (coordinates, bearer tokens, pairing codes) before logging.
     */
    public static function redactMessage(string $message): string
    {
        // Redact Bearer tokens
        $redacted = (string) preg_replace('/Bearer\s+[A-Za-z0-9\-._~+\/]+=*/i', 'Bearer [REDACTED]', $message);
        // Redact 32+ char hex strings (tokens/hashes)
        $redacted = (string) preg_replace('/\b[a-f0-9]{32,64}\b/i', '[REDACTED_TOKEN]', $redacted);
        // Redact decimal coordinate patterns
        $redacted = (string) preg_replace('/[-+]?\d{1,3}\.\d{3,}/', '[REDACTED_COORD]', $redacted);
        return $redacted;
    }

    /**
     * Safely log an internal error without exposing secrets or coordinates.
     */
    public static function logError(string $context, Throwable|string $error): void
    {
        $raw = $error instanceof Throwable ? $error->getMessage() : $error;
        error_log(sprintf('[LocaShare] %s: %s', $context, self::redactMessage($raw)));
    }
}
