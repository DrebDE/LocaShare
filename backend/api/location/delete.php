<?php
/**
 * LocaShare API - POST|DELETE /api/location/delete
 *
 * Deletes the stored location for a device.
 * Can be invoked by the authenticated phone owner (Bearer token)
 * OR by an authenticated paired dashboard session (Session cookie + CSRF token).
 */

require_once __DIR__ . '/../../includes/Database.php';
require_once __DIR__ . '/../../includes/Auth.php';
require_once __DIR__ . '/../../includes/RateLimiter.php';
require_once __DIR__ . '/../../includes/Response.php';
require_once __DIR__ . '/../../includes/Security.php';
require_once __DIR__ . '/../../includes/DeviceService.php';

Response::setApiHeaders();

$method = $_SERVER['REQUEST_METHOD'] ?? '';
if (!in_array($method, ['POST', 'DELETE'], true)) {
    Response::error('Method not allowed. Use POST or DELETE.', 405, 'METHOD_NOT_ALLOWED');
}

RateLimiter::check('api');

$input = Security::readJsonBody(true);

// Check if called with phone Bearer token
$authHeader = $_SERVER['HTTP_AUTHORIZATION'] ?? $_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? '';
if (stripos($authHeader, 'Bearer ') === 0) {
    $device = Auth::requireDevice($input);
    $result = DeviceService::deleteLocation($device['id']);
    Response::success($result);
}

// Otherwise require an authenticated dashboard session + CSRF token
$session = Auth::requireDashboardSession(true, $input);
$deviceId = isset($input['device_id']) && is_string($input['device_id'])
    ? trim($input['device_id'])
    : (isset($_GET['device_id']) && is_string($_GET['device_id']) ? trim($_GET['device_id']) : '');

if ($deviceId === '') {
    Response::error('Missing device_id.', 400, 'MISSING_DEVICE_ID');
}

$result = DeviceService::deleteLocationFromDashboard($session['id'], $deviceId);
Response::success($result);
