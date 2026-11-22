<?php
/**
 * LocaShare API - POST /api/family/places/delete
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

$placeId = isset($input['place_id']) && is_string($input['place_id']) ? $input['place_id'] : '';
Response::success(FamilyService::deleteSavedPlace($device['id'], $placeId));
