<?php
/**
 * LocaShare API - POST|DELETE /api/device/unregister
 *
 * Allows the phone owner to unregister the device, invalidating its token,
 * revoking all dashboard pairings, and deleting its stored location.
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
$device = Auth::requireDevice($input);

$result = DeviceService::unregisterDevice($device['id']);
Response::success($result);
