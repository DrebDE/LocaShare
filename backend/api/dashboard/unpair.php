<?php
/**
 * LocaShare API - POST /api/dashboard/unpair
 *
 * Unpairs a device from the current laptop dashboard session
 * (or acknowledges a phone-initiated revocation notice).
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

$input = Security::readJsonBody(false);
$session = Auth::requireDashboardSession(true, $input);

$deviceId = isset($input['device_id']) && is_string($input['device_id'])
    ? trim($input['device_id'])
    : '';

if ($deviceId === '') {
    Response::error('Missing device_id.', 400, 'MISSING_DEVICE_ID');
}

$deleteLocation  = !empty($input['delete_location']);
$acknowledgeOnly = !empty($input['acknowledge_only']);

$result = DeviceService::unpairDeviceFromDashboard(
    $session['id'],
    $deviceId,
    $deleteLocation,
    $acknowledgeOnly
);

Response::success($result);
