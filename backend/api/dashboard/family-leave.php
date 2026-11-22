<?php
/**
 * LocaShare API - POST /api/dashboard/family-leave
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

RateLimiter::check('api');

$input = Security::readJsonBody(false);
$session = Auth::requireDashboardSession(true, $input);

$circleId = isset($input['circle_id']) && is_string($input['circle_id']) ? $input['circle_id'] : '';
Response::success(FamilyService::leaveCircleFromDashboard($session['id'], $circleId));
