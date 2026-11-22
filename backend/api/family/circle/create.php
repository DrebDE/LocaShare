<?php
/**
 * LocaShare API - POST /api/family/circle/create
 */
require_once __DIR__ . '/../../../includes/Auth.php';
require_once __DIR__ . '/../../../includes/RateLimiter.php';
require_once __DIR__ . '/../../../includes/Response.php';
require_once __DIR__ . '/../../../includes/Security.php';
require_once __DIR__ . '/../../../includes/FamilyService.php';

Response::setApiHeaders();

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    Response::error('Method not allowed. Use POST.', 405, 'METHOD_NOT_ALLOWED');
}

RateLimiter::check('api');

$input = Security::readJsonBody(false);
$device = Auth::requireDevice($input);

$circleName = isset($input['name']) && is_string($input['name']) ? $input['name'] : 'Our Family';
$memberName = isset($input['member_name']) && is_string($input['member_name']) ? $input['member_name'] : '';

$snapshot = FamilyService::createCircle($device['id'], $circleName, $memberName);
Response::success($snapshot, 201);
