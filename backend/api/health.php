<?php
/**
 * LocaShare API - GET /api/health
 *
 * Returns backend and database connectivity status for diagnostics and monitoring.
 */

declare(strict_types=1);

require_once __DIR__ . '/../includes/Database.php';
require_once __DIR__ . '/../includes/Response.php';
require_once __DIR__ . '/../includes/Security.php';

Response::setApiHeaders();

if (($_SERVER['REQUEST_METHOD'] ?? 'GET') !== 'GET') {
    Response::error('Method not allowed. Expected GET.', 405, 'METHOD_NOT_ALLOWED');
}

try {
    $db = Database::getConnection();
    $db->query('SELECT 1');

    Response::success([
        'status'      => 'ok',
        'db'          => 'connected',
        'driver'      => Database::getDriver(),
        'server_time' => gmdate('Y-m-d\TH:i:s\Z'),
    ]);
} catch (Throwable $e) {
    if ($e instanceof ResponseTerminateException) {
        throw $e;
    }
    Security::logError('Health check failed', $e);
    Response::error('Service unhealthy.', 503, 'SERVICE_UNAVAILABLE');
}
