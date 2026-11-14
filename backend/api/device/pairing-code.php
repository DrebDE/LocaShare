<?php
/**
 * LocaShare API - POST /api/device/pairing-code
 *
 * Generates a new short-lived single-use pairing code for an authenticated phone
 * and revokes any previous unused codes for that phone.
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

RateLimiter::check('register');

$input = Security::readJsonBody(true);
$device = Auth::requireDevice($input);

$result = DeviceService::generatePairingCode($device['id']);
Response::success($result);
