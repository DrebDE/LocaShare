<?php
/**
 * LocaShare API - POST /api/device/unpair
 *
 * Allows the phone owner to immediately revoke all dashboard pairings
 * and optionally clear the stored location.
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

$clearLocation = !array_key_exists('clear_location', $input) || (bool) $input['clear_location'];
$result = DeviceService::unpairAllDashboards($device['id'], $clearLocation);
Response::success($result);
