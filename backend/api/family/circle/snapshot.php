<?php
/**
 * LocaShare API - GET /api/family/circle/snapshot
 */
require_once __DIR__ . '/../../../includes/Auth.php';
require_once __DIR__ . '/../../../includes/RateLimiter.php';
require_once __DIR__ . '/../../../includes/Response.php';
require_once __DIR__ . '/../../../includes/FamilyService.php';

Response::setApiHeaders();

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'GET') {
    Response::error('Method not allowed. Use GET.', 405, 'METHOD_NOT_ALLOWED');
}

RateLimiter::check('api');

$device = Auth::requireDevice(null);
$since = isset($_GET['events_since']) && is_string($_GET['events_since']) ? $_GET['events_since'] : null;

Response::success(FamilyService::getCircleSnapshotForDevice($device['id'], $since));
