<?php
/**
 * LocaShare - Optional Firebase Cloud Messaging (FCM HTTP v1) Push Relay
 *
 * Sends push alerts when a family member enters or leaves Home, School, Work,
 * or another Saved Place, when FCM credentials are configured in backend/.env.
 * Gracefully returns 0 when unconfigured (devices still receive alerts via
 * built-in background alert syncing).
 */

require_once __DIR__ . '/Security.php';

class FcmNotifier
{
    public static function isConfigured(): bool
    {
        $config = require __DIR__ . '/../config/app.php';
        $fcm = $config['fcm'] ?? [];
        return !empty($fcm['project_id'])
            && !empty($fcm['client_email'])
            && !empty($fcm['private_key'])
            && function_exists('openssl_sign');
    }

    /**
     * Send a place transition alert to the provided FCM registration tokens.
     *
     * @param array<int, string> $tokens
     * @param array<string, mixed> $event
     */
    public static function sendPlaceEvent(array $tokens, array $event): int
    {
        if (empty($tokens) || !self::isConfigured()) {
            return 0;
        }

        $config = require __DIR__ . '/../config/app.php';
        $fcm = $config['fcm'];

        try {
            $accessToken = self::fetchGoogleAccessToken(
                (string) $fcm['client_email'],
                (string) $fcm['private_key']
            );
            if ($accessToken === '') {
                return 0;
            }

            $member = (string) ($event['member_name'] ?? 'Family member');
            $place = (string) ($event['place_name'] ?? 'place');
            $category = (string) ($event['place_category'] ?? 'custom');
            $type = (string) ($event['event_type'] ?? 'entered');
            $verb = $type === 'exited' ? 'left' : 'arrived at';

            $title = "{$member} {$verb} {$place}";
            $body = ($category === 'home' && $type === 'exited')
                ? 'Live away-from-home tracking is now active.'
                : (($category === 'home' && $type === 'entered')
                    ? 'Arrived safely at Home (Battery Saver mode active).'
                    : 'Tap to open Family Map');

            $endpoint = sprintf(
                'https://fcm.googleapis.com/v1/projects/%s/messages:send',
                rawurlencode((string) $fcm['project_id'])
            );

            $sent = 0;
            foreach ($tokens as $token) {
                $token = trim((string) $token);
                if ($token === '') {
                    continue;
                }
                $payload = json_encode([
                    'message' => [
                        'token'        => $token,
                        'notification' => ['title' => $title, 'body' => $body],
                        'data'         => [
                            'event_id'    => (string) ($event['event_id'] ?? ''),
                            'place_id'    => (string) ($event['place_id'] ?? ''),
                            'place_name'  => $place,
                            'event_type'  => $type,
                            'member_name' => $member,
                        ],
                        'android' => [
                            'priority'     => 'high',
                            'notification' => ['channel_id' => 'locashare_family_alerts_channel'],
                        ],
                    ],
                ]);
                if ($payload !== false && self::postJson($endpoint, $payload, 'Authorization: Bearer ' . $accessToken)) {
                    $sent++;
                }
            }
            return $sent;
        } catch (Throwable $e) {
            Security::logError('FCM notification failed', $e);
            return 0;
        }
    }

    private static function fetchGoogleAccessToken(string $clientEmail, string $privateKeyPem): string
    {
        $now = time();
        $header = self::base64UrlEncode((string) json_encode(['alg' => 'RS256', 'typ' => 'JWT']));
        $claims = self::base64UrlEncode((string) json_encode([
            'iss'   => $clientEmail,
            'scope' => 'https://www.googleapis.com/auth/firebase.messaging',
            'aud'   => 'https://oauth2.googleapis.com/token',
            'iat'   => $now,
            'exp'   => $now + 3600,
        ]));

        $unsigned = $header . '.' . $claims;
        $pem = str_replace('\n', "\n", $privateKeyPem);
        $signature = '';
        if (!@openssl_sign($unsigned, $signature, $pem, OPENSSL_ALGO_SHA256)) {
            return '';
        }
        $jwt = $unsigned . '.' . self::base64UrlEncode($signature);

        $body = http_build_query([
            'grant_type' => 'urn:ietf:params:oauth:grant-type:jwt-bearer',
            'assertion'  => $jwt,
        ]);

        $ctx = stream_context_create([
            'http' => [
                'method'  => 'POST',
                'header'  => "Content-Type: application/x-www-form-urlencoded\r\n",
                'content' => $body,
                'timeout' => 8,
            ],
        ]);
        $raw = @file_get_contents('https://oauth2.googleapis.com/token', false, $ctx);
        if (!is_string($raw) || $raw === '') {
            return '';
        }
        $decoded = json_decode($raw, true);
        return is_array($decoded) && !empty($decoded['access_token'])
            ? (string) $decoded['access_token']
            : '';
    }

    private static function postJson(string $url, string $jsonBody, string $authHeader): bool
    {
        $ctx = stream_context_create([
            'http' => [
                'method'        => 'POST',
                'header'        => "Content-Type: application/json\r\n{$authHeader}\r\n",
                'content'       => $jsonBody,
                'timeout'       => 8,
                'ignore_errors' => true,
            ],
        ]);
        $res = @file_get_contents($url, false, $ctx);
        if ($res === false) {
            return false;
        }
        $statusLine = $http_response_header[0] ?? '';
        return (bool) preg_match('#\s2\d\d\s#', $statusLine);
    }

    private static function base64UrlEncode(string $data): string
    {
        return rtrim(strtr(base64_encode($data), '+/', '-_'), '=');
    }
}
