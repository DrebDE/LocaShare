<?php
/**
 * LocaShare API - POST /api/device/heartbeat
 *
 * Updates the phone's connection heartbeat and operational state
 * without overwriting the stored location fix or its recorded timestamp.
 */

require_once __DIR__ . '/../../includes/Database.php';
require_once __DIR__ . '/../../includes/Auth.php';
require_once __DIR__ . '/../../includes/RateLimiter.php';
require_once __DIR__ . '/../../includes/Response.php';
require_once __DIR__ . '/../../includes/Security.php';
require_once __DIR__ . '/../../includes/DeviceService.php';

Response::setApiHeaders();

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    Response::error('Method not allowed. Use POST.', 405, 'METHOD_NOT_ALLOWED');
}

RateLimiter::check('api');

$input = Security::readJsonBody(true);
$device = Auth::requireDevice($input);

$status = DeviceService::recordHeartbeat($device['id'], $input);
Response::success([
    'message' => 'Heartbeat recorded.',
    'status'  => $status,
]);
