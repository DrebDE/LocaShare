<?php
/**
 * LocaShare API - GET /api/dashboard/session
 *
 * Initializes or refreshes the browser's HttpOnly dashboard session cookie
 * and returns the CSRF token and polling configuration.
 */

require_once __DIR__ . '/../../includes/Database.php';
require_once __DIR__ . '/../../includes/Auth.php';
require_once __DIR__ . '/../../includes/RateLimiter.php';
require_once __DIR__ . '/../../includes/Response.php';
require_once __DIR__ . '/../../includes/Security.php';
require_once __DIR__ . '/../../includes/DeviceService.php';

Response::setApiHeaders();

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'GET') {
    Response::error('Method not allowed. Use GET.', 405, 'METHOD_NOT_ALLOWED');
}

RateLimiter::check('api');

$config = require __DIR__ . '/../../config/app.php';
$session = Auth::getOrCreateDashboardSession();
$devicesData = DeviceService::getPairedDevicesForDashboard($session['id']);

$googleMapsApiKey = (string) ($config['dashboard']['google_maps_api_key'] ?? '');

Response::success([
    'csrf_token'         => $session['csrf_token'],
    'session_expires_at' => $session['expires_at'],
    'poll_interval_ms'   => (int) ($config['dashboard']['poll_interval_ms'] ?? 10000),
    'map_config'         => [
        'default_provider'    => (string) ($config['dashboard']['default_map_provider'] ?? 'esri_street'),
        'google_maps_enabled' => $googleMapsApiKey !== '',
        'google_maps_api_key' => $googleMapsApiKey !== '' ? $googleMapsApiKey : null,
    ],
    'thresholds'         => $devicesData['thresholds'],
    'devices'            => $devicesData['devices'],
    'revoked_pairings'   => $devicesData['revoked_pairings'],
    'server_time'        => $devicesData['server_time'],
]);
