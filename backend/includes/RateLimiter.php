<?php
/**
 * LocaShare - Bucketed Rate Limiter
 *
 * File-based rate limiter supporting separate buckets for general API calls,
 * device registration/pairing-code generation, and dashboard pairing attempts.
 */

require_once __DIR__ . '/Response.php';

class RateLimiter
{
    /**
     * Check if the current request exceeds the configured rate limit for $bucket.
     *
     * @param string      $bucket  One of 'api', 'register', 'pair'.
     * @param string|null $subject Optional subject key (defaults to client IP).
     */
    public static function check(string $bucket = 'api', ?string $subject = null): bool
    {
        $config = require __DIR__ . '/../config/app.php';
        $rlConfig = $config['rate_limit'] ?? [];
        $bucketConfig = $rlConfig[$bucket] ?? $rlConfig['api'] ?? [
            'max_requests'   => 120,
            'window_seconds' => 60,
        ];

        $maxRequests = max(1, (int) ($bucketConfig['max_requests'] ?? 120));
        $windowSec   = max(1, (int) ($bucketConfig['window_seconds'] ?? 60));

        $storageDir = (string) ($rlConfig['storage_dir'] ?? sys_get_temp_dir());
        if (!is_dir($storageDir)) {
            @mkdir($storageDir, 0775, true);
        }

        $ip = $subject ?? ($_SERVER['REMOTE_ADDR'] ?? '127.0.0.1');
        $key = 'locashare_rl_' . preg_replace('/[^a-z0-9_]/i', '_', $bucket) . '_' . hash('sha256', $ip);
        $file = rtrim($storageDir, '/\\') . DIRECTORY_SEPARATOR . $key . '.json';

        $now = time();
        $data = ['count' => 0, 'window_start' => $now];

        if (is_file($file)) {
            $raw = @file_get_contents($file);
            if (is_string($raw) && $raw !== '') {
                $decoded = json_decode($raw, true);
                if (is_array($decoded) && isset($decoded['count'], $decoded['window_start'])) {
                    $data = $decoded;
                }
            }
        }

        if (($now - (int) $data['window_start']) >= $windowSec) {
            $data = ['count' => 0, 'window_start' => $now];
        }

        $data['count'] = ((int) $data['count']) + 1;
        @file_put_contents($file, json_encode($data), LOCK_EX);

        if ($data['count'] > $maxRequests) {
            $retryAfter = max(1, $windowSec - ($now - (int) $data['window_start']));
            if (!headers_sent()) {
                header('Retry-After: ' . $retryAfter);
            }
            Response::error(
                'Rate limit exceeded. Please wait before trying again.',
                429,
                'RATE_LIMIT_EXCEEDED',
                ['retry_after_seconds' => $retryAfter]
            );
        }

        return true;
    }

    /**
     * Clear rate-limit tracking files in the configured storage directory (used by tests).
     */
    public static function reset(): void
    {
        $config = require __DIR__ . '/../config/app.php';
        $storageDir = (string) ($config['rate_limit']['storage_dir'] ?? sys_get_temp_dir());
        if (!is_dir($storageDir)) {
            return;
        }
        $files = glob(rtrim($storageDir, '/\\') . DIRECTORY_SEPARATOR . 'locashare_rl_*.json');
        if (is_array($files)) {
            foreach ($files as $f) {
                @unlink($f);
            }
        }
    }
}
