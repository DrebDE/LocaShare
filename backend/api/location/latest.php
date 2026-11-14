<?php
/**
 * LocaShare API - GET /api/location/latest
 *
 * Returns the latest location and status ONLY for devices paired to the
 * authenticated dashboard session. Unpaired browsers cannot read location data.
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

// Require a valid dashboard session cookie
$session = Auth::requireDashboardSession(false);

$data = DeviceService::getPairedDevicesForDashboard($session['id']);
$requestedDeviceId = isset($_GET['device_id']) && is_string($_GET['device_id'])
    ? trim($_GET['device_id'])
    : '';

if ($requestedDeviceId !== '') {
    foreach ($data['devices'] as $dev) {
        if ($dev['device_id'] === $requestedDeviceId) {
            Response::success([
                'device'      => $dev,
                'location'    => $dev['location'],
                'thresholds'  => $data['thresholds'],
                'server_time' => $data['server_time'],
            ]);
        }
    }
    Response::error('Device is not paired with this dashboard session.', 403, 'FORBIDDEN_DEVICE');
}

$primaryDevice = $data['devices'][0] ?? null;

Response::success([
    'device'           => $primaryDevice,
    'location'         => $primaryDevice ? $primaryDevice['location'] : null,
    'devices'          => $data['devices'],
    'revoked_pairings' => $data['revoked_pairings'],
    'thresholds'       => $data['thresholds'],
    'server_time'      => $data['server_time'],
]);
