<?php
/**
 * LocaShare Backend Integration Test Suite
 *
 * Executes full HTTP requests (headers, Set-Cookie flags, status codes, JSON bodies)
 * through backend/router.php using php-cgi (zero port binding required).
 *
 * Run: C:\xampp\php\php.exe locashare\backend\tests\run_tests.php
 */

declare(strict_types=1);

if (PHP_SAPI !== 'cli') {
    exit('CLI only.');
}

$backendDir = realpath(__DIR__ . '/..');
if ($backendDir === false) {
    fwrite(STDERR, "Unable to locate backend directory.\n");
    exit(1);
}

$tmpRoot = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'locashare_test_' . bin2hex(random_bytes(6));
mkdir($tmpRoot, 0750, true);
$dbPath = $tmpRoot . DIRECTORY_SEPARATOR . 'test.sqlite';
$rlDir = $tmpRoot . DIRECTORY_SEPARATOR . 'ratelimit';
$logPath = $tmpRoot . DIRECTORY_SEPARATOR . 'php_server.log';
mkdir($rlDir, 0750, true);

$baseEnv = array_merge(getenv(), [
    'LOCASHARE_DB_DRIVER'                => 'sqlite',
    'LOCASHARE_DB_SQLITE_PATH'           => $dbPath,
    'LOCASHARE_RATE_LIMIT_DIR'           => $rlDir,
    'LOCASHARE_PAIRING_TTL_SECONDS'      => '300',
    'LOCASHARE_ONLINE_THRESHOLD_SECONDS' => '90',
    'LOCASHARE_LOCATION_STALE_SECONDS'   => '180',
    'LOCASHARE_RATE_LIMIT_PAIR_MAX'      => '6',
    'LOCASHARE_RATE_LIMIT_PAIR_WINDOW'   => '300',
    'LOCASHARE_RATE_LIMIT_API_MAX'       => '500',
    'LOCASHARE_RATE_LIMIT_REGISTER_MAX'  => '50',
    'LOCASHARE_COOKIE_SECURE'            => 'auto',
    'LOCASHARE_TIMEZONE'                 => 'UTC',
]);

$phpCgiBin = findPhpCgi();
if ($phpCgiBin === null) {
    fwrite(STDERR, "Unable to locate php-cgi executable next to " . PHP_BINARY . "\n");
    exit(1);
}

$passed = 0;
$failed = 0;
$secretsToCheck = [];

function findPhpCgi(): ?string
{
    $dir = dirname(PHP_BINARY);
    foreach (['php-cgi.exe', 'php-cgi'] as $candidate) {
        $full = $dir . DIRECTORY_SEPARATOR . $candidate;
        if (is_file($full)) {
            return $full;
        }
    }
    return null;
}

function assertTrue(bool $cond, string $message): void
{
    global $passed, $failed;
    if ($cond) {
        $passed++;
        echo "  [PASS] {$message}\n";
    } else {
        $failed++;
        fwrite(STDERR, "  [FAIL] {$message}\n");
    }
}

function assertEquals(mixed $expected, mixed $actual, string $message): void
{
    $ok = ($expected === $actual);
    if (!$ok) {
        $message .= ' (expected=' . var_export($expected, true) . ', actual=' . var_export($actual, true) . ')';
    }
    assertTrue($ok, $message);
}

function httpRequest(
    string $method,
    string $pathAndQuery,
    ?array $jsonBody = null,
    array $headers = [],
    ?string $rawBody = null,
    array $extraServerEnv = []
): array {
    global $phpCgiBin, $backendDir, $baseEnv, $logPath;

    $payload = $rawBody;
    if ($jsonBody !== null) {
        $payload = json_encode($jsonBody);
        $headers[] = 'Content-Type: application/json';
    }
    $payload = $payload ?? '';

    $parts = parse_url($pathAndQuery);
    $path = $parts['path'] ?? '/';
    $query = $parts['query'] ?? '';

    $cgiEnv = array_merge($baseEnv, [
        'REDIRECT_STATUS'   => '200',
        'SCRIPT_FILENAME'   => $backendDir . DIRECTORY_SEPARATOR . 'router.php',
        'SCRIPT_NAME'       => '/router.php',
        'REQUEST_METHOD'    => strtoupper($method),
        'REQUEST_URI'       => $pathAndQuery,
        'PATH_INFO'         => $path,
        'QUERY_STRING'      => $query,
        'REMOTE_ADDR'       => '127.0.0.1',
        'SERVER_PROTOCOL'   => 'HTTP/1.1',
        'GATEWAY_INTERFACE' => 'CGI/1.1',
        'CONTENT_LENGTH'    => (string) strlen($payload),
    ], $extraServerEnv);

    foreach ($headers as $h) {
        $colon = strpos($h, ':');
        if ($colon === false) {
            continue;
        }
        $name = trim(substr($h, 0, $colon));
        $val = trim(substr($h, $colon + 1));
        $upper = strtoupper(str_replace('-', '_', $name));
        if ($upper === 'CONTENT_TYPE') {
            $cgiEnv['CONTENT_TYPE'] = $val;
        } else {
            $cgiEnv['HTTP_' . $upper] = $val;
        }
    }

    $descriptors = [
        0 => ['pipe', 'r'],
        1 => ['pipe', 'w'],
        2 => ['file', $logPath, 'a'],
    ];

    $proc = proc_open(
        [
            $phpCgiBin,
            '-d', 'display_errors=0',
            '-d', 'display_startup_errors=0',
            '-d', 'error_log=' . $logPath,
            '-d', 'cgi.force_redirect=0',
        ],
        $descriptors,
        $pipes,
        $backendDir,
        $cgiEnv
    );
    if (!is_resource($proc)) {
        throw new RuntimeException("Failed to invoke php-cgi for {$pathAndQuery}");
    }

    fwrite($pipes[0], $payload);
    fclose($pipes[0]);
    $rawResp = stream_get_contents($pipes[1]) ?: '';
    fclose($pipes[1]);
    proc_close($proc);

    $sep = strpos($rawResp, "\r\n\r\n");
    $sepLen = 4;
    if ($sep === false) {
        $sep = strpos($rawResp, "\n\n");
        $sepLen = 2;
    }

    $rawHeaders = $sep !== false ? substr($rawResp, 0, $sep) : '';
    $bodyStr = $sep !== false ? substr($rawResp, $sep + $sepLen) : $rawResp;

    $status = 200;
    if (preg_match('/^Status:\s*(\d{3})/mi', $rawHeaders, $m)) {
        $status = (int) $m[1];
    }

    $decoded = json_decode($bodyStr, true);

    return [
        'status'  => $status,
        'headers' => $rawHeaders,
        'body'    => $bodyStr,
        'json'    => is_array($decoded) ? $decoded : null,
    ];
}

function extractSessionCookie(string $rawHeaders): string
{
    if (preg_match('/Set-Cookie:\s*(locashare_session=[^;\r\n]+)/i', $rawHeaders, $m)) {
        return $m[1];
    }
    return '';
}

try {
    echo "Running LocaShare Backend Integration Tests...\n";

    // 1. Health, dashboard shell, and router isolation
    $health = httpRequest('GET', '/api/health');
    assertEquals(200, $health['status'], 'GET /api/health returns 200');
    assertEquals('ok', $health['json']['status'] ?? null, 'Health reports status=ok');
    assertTrue(stripos($health['headers'], 'X-Content-Type-Options: nosniff') !== false, 'Security header X-Content-Type-Options present');

    $dashHtml = httpRequest('GET', '/dashboard/');
    assertEquals(200, $dashHtml['status'], 'GET /dashboard/ serves HTML shell');
    assertTrue(stripos($dashHtml['headers'], 'Content-Security-Policy:') !== false, 'Dashboard enforces strict CSP');

    $rootRedirect = httpRequest('GET', '/');
    assertEquals(302, $rootRedirect['status'], 'GET / redirects cleanly to /dashboard/');

    $blockedCfg = httpRequest('GET', '/config/app.php');
    assertTrue(in_array($blockedCfg['status'], [403, 404], true), 'Direct access to /config/app.php blocked (403/404)');

    // 2. Unpaired browser & unauthorized device access control
    $unpairedDevices = httpRequest('GET', '/api/dashboard/devices');
    assertEquals(401, $unpairedDevices['status'], 'Unpaired browser gets 401 on /api/dashboard/devices');

    $unpairedLatest = httpRequest('GET', '/api/location/latest');
    assertEquals(401, $unpairedLatest['status'], 'Unpaired browser gets 401 on /api/location/latest');

    $noAuthUpdate = httpRequest('POST', '/api/location/update', [
        'device_id'   => 'dev_1234567890abcdef',
        'latitude'    => 14.5995,
        'longitude'   => 120.9842,
        'recorded_at' => gmdate('c'),
    ]);
    assertEquals(401, $noAuthUpdate['status'], 'Unauthorized device update rejected with 401');

    // 3. Register two devices
    $regA = httpRequest('POST', '/api/device/register', ['device_name' => 'Phone A']);
    assertEquals(201, $regA['status'], 'Register Phone A returns 201');
    $devA = $regA['json'];
    assertTrue(
        !empty($devA['device_id']) && !empty($devA['device_token']) && !empty($devA['pairing_code']),
        'Phone A receives id, token, and pairing code'
    );
    assertEquals('waiting_for_pairing', $devA['status_state'] ?? null, 'Phone A initializes in waiting_for_pairing');
    assertEquals(false, $devA['sharing_enabled'] ?? true, 'Phone A sharing_enabled defaults to false');
    $secretsToCheck[] = $devA['device_token'];
    $secretsToCheck[] = $devA['pairing_code'];

    $regB = httpRequest('POST', '/api/device/register', ['device_name' => 'Phone B']);
    assertEquals(201, $regB['status'], 'Register Phone B returns 201');
    $devB = $regB['json'];
    $secretsToCheck[] = $devB['device_token'];
    $secretsToCheck[] = $devB['pairing_code'];

    // 4. Pair Phone A to Dashboard Session 1 over simulated HTTPS; verify cookie attributes & single-use
    $pairA = httpRequest('POST', '/api/dashboard/pair', [
        'pairing_code' => $devA['pairing_code'],
        'label'        => 'Laptop 1',
    ], [], null, ['HTTPS' => 'on']);
    assertEquals(200, $pairA['status'], 'Pairing Phone A succeeds');
    $cookie1 = extractSessionCookie($pairA['headers']);
    assertTrue($cookie1 !== '', 'Dashboard receives session cookie');
    assertTrue(stripos($pairA['headers'], 'HttpOnly') !== false, 'Session cookie is HttpOnly');
    assertTrue(stripos($pairA['headers'], 'Secure') !== false, 'Session cookie is Secure over HTTPS');
    assertTrue(stripos($pairA['headers'], 'SameSite=Strict') !== false, 'Session cookie is SameSite=Strict');
    $csrf1 = $pairA['json']['csrf_token'] ?? '';
    assertTrue($csrf1 !== '', 'Session returns CSRF token');

    $reuseA = httpRequest('POST', '/api/dashboard/pair', ['pairing_code' => $devA['pairing_code']]);
    assertEquals(409, $reuseA['status'], 'Reusing single-use pairing code fails with 409');
    assertEquals('CODE_ALREADY_USED', $reuseA['json']['error_code'] ?? null, 'Reuse returns CODE_ALREADY_USED');

    $invalidCodeTry = httpRequest('POST', '/api/dashboard/pair', ['pairing_code' => 'AAAA-2222']);
    assertEquals(404, $invalidCodeTry['status'], 'Unknown pairing code fails with 404');
    assertEquals('INVALID_CODE', $invalidCodeTry['json']['error_code'] ?? null, 'Unknown code returns INVALID_CODE');

    // Test pairing code refresh revoking old code & expiry enforcement
    $newCodeResp = httpRequest('POST', '/api/device/pairing-code', ['device_id' => $devB['device_id']], [
        'Authorization: Bearer ' . $devB['device_token'],
    ]);
    assertEquals(200, $newCodeResp['status'], 'Phone B generates refreshed pairing code');
    $freshCodeB = $newCodeResp['json']['pairing_code'];
    $secretsToCheck[] = $freshCodeB;

    $oldCodeB = httpRequest('POST', '/api/dashboard/pair', ['pairing_code' => $devB['pairing_code']]);
    assertEquals(410, $oldCodeB['status'], 'Superseded pairing code is revoked (410)');
    assertEquals('CODE_REVOKED', $oldCodeB['json']['error_code'] ?? null, 'Revoked code reports CODE_REVOKED');

    // Force-expire freshCodeB directly in SQLite to verify expiry check
    $pdo = new PDO('sqlite:' . $dbPath);
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $normFreshB = str_replace('-', '', strtoupper($freshCodeB));
    $expiredStmt = $pdo->prepare('UPDATE pairing_codes SET expires_at = ? WHERE code_hash = ?');
    $expiredStmt->execute([gmdate('Y-m-d H:i:s', time() - 60), hash('sha256', $normFreshB)]);

    $expiredTry = httpRequest('POST', '/api/dashboard/pair', ['pairing_code' => $freshCodeB]);
    assertEquals(410, $expiredTry['status'], 'Expired pairing code returns 410');
    assertEquals('CODE_EXPIRED', $expiredTry['json']['error_code'] ?? null, 'Expired code reports CODE_EXPIRED');

    // Generate another code for Phone B and pair it to Dashboard Session 2
    $codeB2Resp = httpRequest('POST', '/api/device/pairing-code', ['device_id' => $devB['device_id']], [
        'Authorization: Bearer ' . $devB['device_token'],
    ]);
    $codeB2 = $codeB2Resp['json']['pairing_code'];
    $secretsToCheck[] = $codeB2;
    $pairB = httpRequest('POST', '/api/dashboard/pair', ['pairing_code' => $codeB2, 'label' => 'Laptop 2']);
    assertEquals(200, $pairB['status'], 'Phone B pairs to Dashboard Session 2');
    $cookie2 = extractSessionCookie($pairB['headers']);

    // 5. Cross-device & cross-session authorization isolation
    $spoofAttempt = httpRequest('POST', '/api/location/update', [
        'device_id'   => $devB['device_id'],
        'latitude'    => 14.5995,
        'longitude'   => 120.9842,
        'recorded_at' => gmdate('c'),
    ], ['Authorization: Bearer ' . $devA['device_token']]);
    assertTrue(in_array($spoofAttempt['status'], [401, 403], true), 'Phone A token cannot update Phone B');

    $mismatchAttempt = httpRequest('POST', '/api/location/update?device_id=' . urlencode($devB['device_id']), [
        'device_id'   => $devA['device_id'],
        'latitude'    => 14.5995,
        'longitude'   => 120.9842,
        'recorded_at' => gmdate('c'),
    ], ['Authorization: Bearer ' . $devA['device_token']]);
    assertEquals(403, $mismatchAttempt['status'], 'Conflicting device_id across query and body rejected with 403');

    $s1Devices = httpRequest('GET', '/api/dashboard/devices', null, ['Cookie: ' . $cookie1]);
    assertEquals(200, $s1Devices['status'], 'Dashboard Session 1 reads paired devices');
    assertEquals(1, count($s1Devices['json']['devices'] ?? []), 'Session 1 sees exactly 1 device');
    assertEquals($devA['device_id'], $s1Devices['json']['devices'][0]['device_id'] ?? null, 'Session 1 sees only Phone A');

    $s1ReadB = httpRequest('GET', '/api/location/latest?device_id=' . urlencode($devB['device_id']), null, ['Cookie: ' . $cookie1]);
    assertEquals(403, $s1ReadB['status'], 'Session 1 forbidden from reading unpaired Phone B');

    // 6. Location validation, payload size checks, and stale-fix vs heartbeat separation
    $badLat = httpRequest('POST', '/api/location/update', [
        'device_id'   => $devA['device_id'],
        'latitude'    => 95.0,
        'longitude'   => 120.0,
        'recorded_at' => gmdate('c'),
    ], ['Authorization: Bearer ' . $devA['device_token']]);
    assertTrue(in_array($badLat['status'], [400, 422], true), 'Rejects out-of-range latitude > 90');

    $badLng = httpRequest('POST', '/api/location/update', [
        'device_id'   => $devA['device_id'],
        'latitude'    => 14.5,
        'longitude'   => -181.0,
        'recorded_at' => gmdate('c'),
    ], ['Authorization: Bearer ' . $devA['device_token']]);
    assertTrue(in_array($badLng['status'], [400, 422], true), 'Rejects out-of-range longitude < -180');

    $badTime = httpRequest('POST', '/api/location/update', [
        'device_id'   => $devA['device_id'],
        'latitude'    => 14.5,
        'longitude'   => 120.9,
        'recorded_at' => gmdate('c', time() + 3600),
    ], ['Authorization: Bearer ' . $devA['device_token']]);
    assertTrue(in_array($badTime['status'], [400, 422], true), 'Rejects future timestamp');

    $hugePayload = json_encode([
        'device_id'   => $devA['device_id'],
        'latitude'    => 14.5,
        'longitude'   => 120.9,
        'recorded_at' => gmdate('c'),
        'padding'     => str_repeat('x', 20000),
    ]);
    $tooLarge = httpRequest('POST', '/api/location/update', null, [
        'Authorization: Bearer ' . $devA['device_token'],
        'Content-Type: application/json',
    ], $hugePayload);
    assertEquals(413, $tooLarge['status'], 'Rejects oversized payload (>16KB) with 413');

    $lat1 = 37.4219983;
    $lng1 = -122.0840575;
    $secretsToCheck[] = '37.4219983';
    $secretsToCheck[] = '-122.0840575';

    $upd1 = httpRequest('POST', '/api/location/update', [
        'device_id'    => $devA['device_id'],
        'latitude'     => $lat1,
        'longitude'    => $lng1,
        'accuracy'     => 11.4,
        'recorded_at'  => gmdate('c', time() - 600), // 10 minutes old (stale fix!)
        'battery'      => 82,
        'is_charging'  => false,
        'network_type' => 'mobile',
    ], ['Authorization: Bearer ' . $devA['device_token']]);
    assertEquals(200, $upd1['status'], 'Valid location update succeeds');

    // Older out-of-order point is ignored without overwriting newer point
    $olderUpd = httpRequest('POST', '/api/location/update', [
        'device_id'   => $devA['device_id'],
        'latitude'    => 35.0,
        'longitude'   => -120.0,
        'accuracy'    => 50.0,
        'recorded_at' => gmdate('c', time() - 1200),
    ], ['Authorization: Bearer ' . $devA['device_token']]);
    assertEquals(200, $olderUpd['status'], 'Older out-of-order location returns 200 safely');
    assertEquals(true, $olderUpd['json']['ignored_older_fix'] ?? false, 'Older out-of-order fix is flagged ignored_older_fix=true');

    // Heartbeat without new fix keeps old location_recorded_at stale while phone is online!
    $hb = httpRequest('POST', '/api/device/heartbeat', [
        'device_id'       => $devA['device_id'],
        'sharing_enabled' => true,
        'status_state'    => 'no_gps_fix',
        'network_type'    => 'wifi',
    ], ['Authorization: Bearer ' . $devA['device_token']]);
    assertEquals(200, $hb['status'], 'Heartbeat without coordinates succeeds');

    $latestA = httpRequest('GET', '/api/location/latest?device_id=' . urlencode($devA['device_id']), null, ['Cookie: ' . $cookie1]);
    assertEquals(200, $latestA['status'], 'Session 1 reads latest location');
    $devView = $latestA['json']['device'] ?? [];
    assertEquals(true, $devView['is_online'] ?? false, 'Phone reports online from recent heartbeat');
    assertEquals('no_gps_fix', $devView['status_state'] ?? null, 'Phone reports no_gps_fix state');
    assertEquals('stale', $devView['location_state'] ?? null, 'Old location fix remains labeled stale even after recent heartbeat');
    assertEquals(false, $devView['is_location_fresh'] ?? true, 'is_location_fresh is false for stale fix');
    assertEquals($lat1, $devView['location']['latitude'] ?? null, 'Ignored older fix did not overwrite newer coordinates');

    // Verify no location_logs table exists / latest-only storage
    $tables = $pdo->query("SELECT name FROM sqlite_master WHERE type='table'")->fetchAll(PDO::FETCH_COLUMN);
    assertTrue(!in_array('location_logs', $tables, true), 'Default schema stores latest location only without route history table');

    // 7. Deletion, phone-side unpair, revocation acknowledge, dashboard unpair, and unregistration
    $delResp = httpRequest('POST', '/api/location/delete', ['device_id' => $devA['device_id']], [
        'Authorization: Bearer ' . $devA['device_token'],
    ]);
    assertEquals(200, $delResp['status'], 'Phone deletes stored location');
    assertEquals(true, $delResp['json']['location_deleted'] ?? false, 'Delete confirms location_deleted=true');

    $afterDel = httpRequest('GET', '/api/location/latest?device_id=' . urlencode($devA['device_id']), null, ['Cookie: ' . $cookie1]);
    assertTrue(
        is_array($afterDel['json']) && array_key_exists('location', $afterDel['json']) && $afterDel['json']['location'] === null,
        'Stored location is null after deletion'
    );

    $unpairPhone = httpRequest('POST', '/api/device/unpair', [
        'device_id'      => $devA['device_id'],
        'clear_location' => true,
    ], ['Authorization: Bearer ' . $devA['device_token']]);
    assertEquals(200, $unpairPhone['status'], 'Phone revokes dashboard pairings via /api/device/unpair');
    assertEquals(1, $unpairPhone['json']['revoked_pairings'] ?? -1, 'Revoked count matches active dashboards');

    $afterRevoke = httpRequest('GET', '/api/dashboard/devices', null, ['Cookie: ' . $cookie1]);
    assertEquals(0, count($afterRevoke['json']['devices'] ?? ['x']), 'Session 1 sees 0 active devices after revocation');
    assertEquals(1, count($afterRevoke['json']['revoked_pairings'] ?? []), 'Session 1 sees revocation notice');
    $afterRevokeRead = httpRequest('GET', '/api/location/latest?device_id=' . urlencode($devA['device_id']), null, ['Cookie: ' . $cookie1]);
    assertEquals(403, $afterRevokeRead['status'], 'Session 1 blocked from /api/location/latest after revocation');

    $ackRevoked = httpRequest('POST', '/api/dashboard/unpair', [
        'device_id'        => $devA['device_id'],
        'acknowledge_only' => true,
    ], ['Cookie: ' . $cookie1, 'X-CSRF-Token: ' . $csrf1]);
    assertEquals(200, $ackRevoked['status'], 'Dashboard acknowledges revocation notice');

    // Dashboard-side unpair with CSRF enforcement (using Session 2 & Phone B)
    $noCsrfUnpair = httpRequest('POST', '/api/dashboard/unpair', [
        'device_id' => $devB['device_id'],
    ], ['Cookie: ' . $cookie2]);
    assertEquals(403, $noCsrfUnpair['status'], 'Dashboard unpair rejects missing CSRF token with 403');

    $csrf2 = $pairB['json']['csrf_token'] ?? '';
    $validUnpair = httpRequest('POST', '/api/dashboard/unpair', [
        'device_id' => $devB['device_id'],
    ], ['Cookie: ' . $cookie2, 'X-CSRF-Token: ' . $csrf2]);
    assertEquals(200, $validUnpair['status'], 'Dashboard unpair succeeds with valid CSRF token');

    // Unregister Phone A -> invalidates token immediately & blocks unused codes
    $freshAfterUnpair = httpRequest('POST', '/api/device/pairing-code', ['device_id' => $devA['device_id']], [
        'Authorization: Bearer ' . $devA['device_token'],
    ]);
    $unusedCodeA = $freshAfterUnpair['json']['pairing_code'] ?? '';
    $secretsToCheck[] = $unusedCodeA;

    $unregA = httpRequest('POST', '/api/device/unregister', ['device_id' => $devA['device_id']], [
        'Authorization: Bearer ' . $devA['device_token'],
    ]);
    assertEquals(200, $unregA['status'], 'Phone A unregisters cleanly');

    $postUnregUpdate = httpRequest('POST', '/api/location/update', [
        'device_id'   => $devA['device_id'],
        'latitude'    => 14.5,
        'longitude'   => 120.9,
        'recorded_at' => gmdate('c'),
    ], ['Authorization: Bearer ' . $devA['device_token']]);
    assertEquals(401, $postUnregUpdate['status'], 'Unregistered device token is rejected with 401');

    if ($unusedCodeA !== '') {
        $pairUnreg = httpRequest('POST', '/api/dashboard/pair', ['pairing_code' => $unusedCodeA], [], null, ['REMOTE_ADDR' => '127.0.0.2']);
        assertTrue(in_array($pairUnreg['status'], [404, 410], true), 'Pairing code for unregistered device is rejected (status=' . $pairUnreg['status'] . ')');
    }

    // 8. Rate limit enforcement on pairing endpoint (limit configured to 6)
    $rateLimited = false;
    for ($i = 0; $i < 8; $i++) {
        $rlResp = httpRequest('POST', '/api/dashboard/pair', ['pairing_code' => 'ZZZZ-9999']);
        if ($rlResp['status'] === 429) {
            $rateLimited = true;
            assertTrue(stripos($rlResp['headers'], 'Retry-After:') !== false, '429 response includes Retry-After header');
            break;
        }
    }
    assertTrue($rateLimited, 'Pairing endpoint enforces rate limiting with 429');

    // 9. Verify no secrets or coordinates leaked into server logs
    $serverLog = is_file($logPath) ? (file_get_contents($logPath) ?: '') : '';
    $leakFound = false;
    foreach ($secretsToCheck as $secret) {
        if ($secret !== '' && str_contains($serverLog, $secret)) {
            $leakFound = true;
            break;
        }
    }
    assertTrue(!$leakFound, 'Server logs contain zero tokens, pairing codes, or coordinates');

    echo "\nSummary: {$passed} passed, {$failed} failed.\n";
} finally {
    $pdo = null;
    $iter = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($tmpRoot, FilesystemIterator::SKIP_DOTS),
        RecursiveIteratorIterator::CHILD_FIRST
    );
    foreach ($iter as $fileInfo) {
        $fileInfo->isDir() ? @rmdir($fileInfo->getPathname()) : @unlink($fileInfo->getPathname());
    }
    @rmdir($tmpRoot);
}

exit($failed > 0 ? 1 : 0);
