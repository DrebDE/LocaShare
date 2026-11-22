<?php
/**
 * LocaShare API - POST /api/dashboard/family-join
 */
require_once __DIR__ . '/../../includes/Auth.php';
require_once __DIR__ . '/../../includes/RateLimiter.php';
require_once __DIR__ . '/../../includes/Response.php';
require_once __DIR__ . '/../../includes/Security.php';
require_once __DIR__ . '/../../includes/FamilyService.php';

Response::setApiHeaders();

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    Response::error('Method not allowed. Use POST.', 405, 'METHOD_NOT_ALLOWED');
}

RateLimiter::check('circle_join');

$input = Security::readJsonBody(false);

$existingSession = Auth::getOptionalDashboardSession();
if ($existingSession !== null) {
    Auth::verifyCsrfToken($existingSession['csrf_token'], $input);
    $session = $existingSession;
} else {
    $session = Auth::getOrCreateDashboardSession();
}

$inviteCode = isset($input['invite_code']) && is_string($input['invite_code']) ? $input['invite_code'] : '';
if (trim($inviteCode) === '') {
    Response::error('Family invite code is required.', 400, 'MISSING_INVITE_CODE');
}

$result = FamilyService::joinCircleFromDashboard($session['id'], $inviteCode);
$result['csrf_token'] = $session['csrf_token'];

Response::success($result);
