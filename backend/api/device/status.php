<?php
/**
 * LocaShare API - GET /api/device/status
 *
 * Returns the authenticated phone's registration, pairing, and sharing status.
 */

require_once __DIR__ . '/../../includes/Database.php';
require_once __DIR__ . '/../../includes/Auth.php';
require_once __DIR__ . '/../../includes/RateLimiter.php';
require_once __DIR__ . '/../../includes/Response.php';
require_once __DIR__ . '/../../includes/Security.php';
require_once __DIR__ . '/../../includes/DeviceService.php';

Response::setApiHeaders();

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'GET') {
    Response::error('Method not allowed. Use GET.', 405, 'METHOD_NOT_ALLOWED');
}

RateLimiter::check('api');

$device = Auth::requireDevice();
$status = DeviceService::getDeviceStatusForPhone($device['id']);
Response::success(['status' => $status]);
