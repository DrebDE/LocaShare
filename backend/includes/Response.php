<?php
/**
 * LocaShare - Response Helper
 *
 * Standardizes JSON API responses and security headers.
 */

class ResponseTerminateException extends RuntimeException
{
    public int $statusCode;
    public array $payload;

    public function __construct(int $statusCode, array $payload)
    {
        parent::__construct($payload['error'] ?? 'Response terminated', $statusCode);
        $this->statusCode = $statusCode;
        $this->payload = $payload;
    }
}

class Response
{
    private static bool $testMode = false;

    /**
     * Enable or disable non-exiting test mode for automated test suites.
     */
    public static function setTestMode(bool $enabled): void
    {
        self::$testMode = $enabled;
    }

    /**
     * Send a success JSON response.
     */
    public static function success(array $data = [], int $statusCode = 200): void
    {
        $payload = array_merge(['success' => true], $data);
        self::send($payload, $statusCode);
    }

    /**
     * Send an error JSON response.
     */
    public static function error(
        string $message,
        int $statusCode = 400,
        ?string $errorCode = null,
        array $extra = []
    ): void {
        $payload = ['success' => false, 'error' => $message];
        if ($errorCode !== null) {
            $payload['error_code'] = $errorCode;
        }
        if (!empty($extra)) {
            $payload = array_merge($payload, $extra);
        }
        self::send($payload, $statusCode);
    }

    /**
     * Emit HTTP status, headers, and JSON body.
     */
    private static function send(array $payload, int $statusCode): void
    {
        if (self::$testMode) {
            throw new ResponseTerminateException($statusCode, $payload);
        }

        if (!headers_sent()) {
            http_response_code($statusCode);
            header('Content-Type: application/json; charset=utf-8');
        }
        echo json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        exit;
    }

    /**
     * Set standard API security and CORS headers.
     */
    public static function setApiHeaders(): void
    {
        if (self::$testMode || headers_sent()) {
            if (($_SERVER['REQUEST_METHOD'] ?? '') === 'OPTIONS' && self::$testMode) {
                throw new ResponseTerminateException(204, ['success' => true]);
            }
            return;
        }

        $config = require __DIR__ . '/../config/app.php';
        $allowedOrigins = $config['security']['allowed_origins'] ?? [];

        header('Content-Type: application/json; charset=utf-8');
        header('X-Content-Type-Options: nosniff');
        header('X-Frame-Options: DENY');
        header('Referrer-Policy: no-referrer');
        header('Cache-Control: no-store, no-cache, must-revalidate');

        $origin = $_SERVER['HTTP_ORIGIN'] ?? '';
        if ($origin !== '') {
            $hostOrigin = (isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off' ? 'https://' : 'http://')
                . ($_SERVER['HTTP_HOST'] ?? '');

            $isAllowed = ($origin === $hostOrigin)
                || in_array($origin, $allowedOrigins, true)
                || in_array('*', $allowedOrigins, true);

            if ($isAllowed) {
                header('Access-Control-Allow-Origin: ' . $origin);
                header('Access-Control-Allow-Credentials: true');
                header('Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS');
                header('Access-Control-Allow-Headers: Content-Type, Authorization, X-CSRF-Token');
                header('Vary: Origin');
            }
        }

        if (($_SERVER['REQUEST_METHOD'] ?? '') === 'OPTIONS') {
            http_response_code(204);
            exit;
        }
    }
}
