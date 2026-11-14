<?php
/**
 * LocaShare API - POST /api/location/update
 *
 * Receives a location report from an authenticated Android phone.
 * Validates coordinates, accuracy, and timestamps, and stores ONLY the
 * latest location fix per device (never route history).
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
$device = Auth::requireDevice($input);

$result = DeviceService::updateLocation($device['id'], $input);
Response::success($result);
