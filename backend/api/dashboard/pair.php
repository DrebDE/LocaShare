<?php
/**
 * LocaShare API - POST /api/dashboard/pair
 *
 * Pairs the current laptop dashboard session with a phone using its
 * short-lived, single-use pairing code (or scanned QR payload).
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

RateLimiter::check('pair');

$input = Security::readJsonBody(false);

// If the browser already has a session, enforce CSRF token; otherwise bootstrap one
$existingSession = Auth::getOptionalDashboardSession();
if ($existingSession !== null) {
    Auth::verifyCsrfToken($existingSession['csrf_token'], $input);
    $session = $existingSession;
} else {
    $session = Auth::getOrCreateDashboardSession();
}

$rawCode = isset($input['pairing_code']) && is_string($input['pairing_code'])
    ? $input['pairing_code']
    : (isset($input['code']) && is_string($input['code']) ? $input['code'] : '');

if (trim($rawCode) === '') {
    Response::error('Pairing code is required.', 400, 'MISSING_CODE');
}

$result = DeviceService::pairDashboardSession($session['id'], $rawCode);
$result['csrf_token'] = $session['csrf_token'];

Response::success($result);
