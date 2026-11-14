<?php
/**
 * LocaShare API - GET /api/dashboard/devices
 *
 * Returns all devices actively paired with the current dashboard session,
 * along with any unacknowledged pairing revocation notices.
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

$session = Auth::requireDashboardSession(false);
$data = DeviceService::getPairedDevicesForDashboard($session['id']);

Response::success($data);
