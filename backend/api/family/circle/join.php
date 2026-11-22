<?php
/**
 * LocaShare API - POST /api/family/circle/join
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

RateLimiter::check('circle_join');

$input = Security::readJsonBody(false);
$device = Auth::requireDevice($input);

$inviteCode = isset($input['invite_code']) && is_string($input['invite_code']) ? $input['invite_code'] : '';
$memberName = isset($input['member_name']) && is_string($input['member_name']) ? $input['member_name'] : '';

$snapshot = FamilyService::joinCircle($device['id'], $inviteCode, $memberName);
Response::success($snapshot);
