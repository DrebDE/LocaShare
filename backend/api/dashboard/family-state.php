<?php
/**
 * LocaShare API - GET /api/dashboard/family-state
 */
require_once __DIR__ . '/../../includes/Auth.php';
require_once __DIR__ . '/../../includes/RateLimiter.php';
require_once __DIR__ . '/../../includes/Response.php';
require_once __DIR__ . '/../../includes/FamilyService.php';

Response::setApiHeaders();

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'GET') {
    Response::error('Method not allowed. Use GET.', 405, 'METHOD_NOT_ALLOWED');
}

RateLimiter::check('api');

$session = Auth::requireDashboardSession(false);
$since = isset($_GET['events_since']) && is_string($_GET['events_since']) ? $_GET['events_since'] : null;

Response::success(FamilyService::getDashboardFamilyState($session['id'], $since));
