<?php
/**
 * LocaShare API - POST /api/family/push-token
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

$token = isset($input['fcm_token']) && is_string($input['fcm_token']) ? $input['fcm_token'] : '';
$platform = isset($input['platform']) && is_string($input['platform']) ? $input['platform'] : 'android';

Response::success(FamilyService::registerPushToken($device['id'], $token, $platform));
