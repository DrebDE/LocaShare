<?php
/**
 * LocaShare API - POST /api/device/register
 *
 * Self-registers a phone without requiring an account login.
 * Returns a unique device_id, device_token, and a short-lived single-use pairing code.
 */

require_once __DIR__ . '/../../includes/Database.php';
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
$deviceName = isset($input['device_name']) && is_string($input['device_name'])
    ? $input['device_name']
    : 'Android Phone';

$result = DeviceService::registerDevice($deviceName);
Response::success($result, 201);
