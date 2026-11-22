<?php
/**
 * LocaShare - Device, Pairing & Location Domain Service
 *
 * Implements device registration, single-use pairing codes, dashboard pairing,
 * heartbeats, latest-only location storage, unpairing, and data deletion.
 */

require_once __DIR__ . '/Database.php';
require_once __DIR__ . '/Response.php';
require_once __DIR__ . '/Security.php';

class DeviceService
{
    /**
     * Self-register a new Android phone and issue its initial pairing code.
     */
    public static function registerDevice(string $rawDeviceName = 'Android Phone'): array
    {
        $config = require __DIR__ . '/../config/app.php';
        $deviceName = Security::sanitizeDeviceName($rawDeviceName, 'Android Phone');

        $deviceId    = Security::generateDeviceId();
        $deviceToken = Security::generateToken(32);
        $tokenHash   = Security::hashToken($deviceToken);

        $now = time();
        $nowUtc = gmdate('Y-m-d H:i:s', $now);

        $db = Database::getConnection();
        $db->beginTransaction();

        try {
            $stmt = $db->prepare('
                INSERT INTO devices (device_id, device_name, token_hash, registered_at, unregistered_at, updated_at)
                VALUES (?, ?, ?, ?, NULL, ?)
            ');
            $stmt->execute([$deviceId, $deviceName, $tokenHash, $nowUtc, $nowUtc]);
            $deviceDbId = (int) $db->lastInsertId();

            $stmtStatus = $db->prepare('
                INSERT INTO device_status (
                    device_id, sharing_enabled, status_state, network_status,
                    last_heartbeat_at, updated_at
                ) VALUES (?, 0, ?, ?, ?, ?)
            ');
            $stmtStatus->execute([$deviceDbId, 'waiting_for_pairing', 'unknown', $nowUtc, $nowUtc]);

            $pairing = self::insertPairingCode($db, $deviceDbId, $config);

            $db->commit();

            return [
                'device_id'          => $deviceId,
                'device_name'        => $deviceName,
                'device_token'       => $deviceToken,
                'status_state'       => 'waiting_for_pairing',
                'sharing_enabled'    => false,
                'pairing_code'       => $pairing['formatted'],
                'pairing_code_raw'   => $pairing['raw'],
                'pairing_qr_payload' => 'locashare://pair?code=' . rawurlencode($pairing['formatted']),
                'pairing_expires_at' => $pairing['expires_iso'],
                'pairing_ttl_seconds'=> $pairing['ttl_seconds'],
                'registered_at'      => gmdate('Y-m-d\TH:i:s\Z', $now),
            ];
        } catch (Throwable $e) {
            if ($db->inTransaction()) {
                $db->rollBack();
            }
            Security::logError('registerDevice failed', $e);
            Response::error('Failed to register device.', 500, 'REGISTER_FAILED');
        }
    }

    /**
     * Generate a fresh short-lived single-use pairing code for an authenticated device.
     */
    public static function generatePairingCode(int $deviceDbId): array
    {
        $config = require __DIR__ . '/../config/app.php';
        $db = Database::getConnection();
        $nowUtc = gmdate('Y-m-d H:i:s');

        $db->beginTransaction();
        try {
            // Revoke previous unused pairing codes for this device
            $revokeStmt = $db->prepare('
                UPDATE pairing_codes
                SET revoked_at = ?
                WHERE device_id = ? AND used_at IS NULL AND revoked_at IS NULL
            ');
            $revokeStmt->execute([$nowUtc, $deviceDbId]);

            $pairing = self::insertPairingCode($db, $deviceDbId, $config);

            // Count active pairings
            $pairedCount = self::countActivePairings($db, $deviceDbId);
            if ($pairedCount === 0) {
                $upd = $db->prepare('
                    UPDATE device_status
                    SET status_state = CASE WHEN sharing_enabled = 1 THEN status_state ELSE ? END,
                        last_heartbeat_at = ?,
                        updated_at = ?
                    WHERE device_id = ?
                ');
                $upd->execute(['waiting_for_pairing', $nowUtc, $nowUtc, $deviceDbId]);
            }

            $db->commit();

            return [
                'pairing_code'        => $pairing['formatted'],
                'pairing_code_raw'    => $pairing['raw'],
                'pairing_qr_payload'  => 'locashare://pair?code=' . rawurlencode($pairing['formatted']),
                'pairing_expires_at'  => $pairing['expires_iso'],
                'pairing_ttl_seconds' => $pairing['ttl_seconds'],
                'paired_dashboards'   => $pairedCount,
            ];
        } catch (Throwable $e) {
            if ($db->inTransaction()) {
                $db->rollBack();
            }
            Security::logError('generatePairingCode failed', $e);
            Response::error('Failed to generate pairing code.', 500, 'PAIRING_CODE_FAILED');
        }
    }

    /**
     * Pair a laptop dashboard session with a phone using its one-time pairing code.
     */
    public static function pairDashboardSession(int $sessionId, string $rawCodeInput): array
    {
        $normalized = Security::normalizePairingCode($rawCodeInput);
        if ($normalized === '' || !Security::isValidPairingCodeFormat($normalized)) {
            Response::error(
                'Invalid pairing code format. Enter the 8-character code shown on your phone.',
                400,
                'INVALID_CODE'
            );
        }

        $codeHash = Security::hashToken($normalized);
        $now = time();
        $nowUtc = gmdate('Y-m-d H:i:s', $now);

        $db = Database::getConnection();
        $db->beginTransaction();

        try {
            $stmt = $db->prepare('
                SELECT
                    pc.id AS code_id,
                    pc.device_id AS device_db_id,
                    pc.expires_at,
                    pc.used_at,
                    pc.revoked_at,
                    d.device_id AS public_device_id,
                    d.device_name,
                    d.unregistered_at
                FROM pairing_codes pc
                JOIN devices d ON d.id = pc.device_id
                WHERE pc.code_hash = ?
                LIMIT 1
            ');
            $stmt->execute([$codeHash]);
            $codeRow = $stmt->fetch();

            if (!$codeRow) {
                $db->rollBack();
                Response::error(
                    'Invalid pairing code. Check the code displayed on your phone and try again.',
                    404,
                    'INVALID_CODE'
                );
            }

            if ($codeRow['unregistered_at'] !== null) {
                $db->rollBack();
                Response::error(
                    'This phone has been unregistered. Register the device again on the phone.',
                    410,
                    'DEVICE_UNREGISTERED'
                );
            }

            if ($codeRow['used_at'] !== null) {
                $db->rollBack();
                Response::error(
                    'This pairing code has already been used. Tap "New pairing code" on your phone to pair another browser.',
                    409,
                    'CODE_ALREADY_USED'
                );
            }

            if ($codeRow['revoked_at'] !== null) {
                $db->rollBack();
                Response::error(
                    'This pairing code is no longer active. Use the newest code displayed on your phone.',
                    410,
                    'CODE_REVOKED'
                );
            }

            $expiresEpoch = strtotime((string) $codeRow['expires_at'] . ' UTC');
            if ($expiresEpoch === false || $expiresEpoch <= $now) {
                $db->rollBack();
                Response::error(
                    'This pairing code has expired. Tap "New pairing code" on your phone and try again.',
                    410,
                    'CODE_EXPIRED'
                );
            }

            // Atomically consume the single-use code
            $consumeStmt = $db->prepare('
                UPDATE pairing_codes
                SET used_at = ?
                WHERE id = ? AND used_at IS NULL AND revoked_at IS NULL
            ');
            $consumeStmt->execute([$nowUtc, (int) $codeRow['code_id']]);
            if ($consumeStmt->rowCount() !== 1) {
                $db->rollBack();
                Response::error(
                    'This pairing code has already been used.',
                    409,
                    'CODE_ALREADY_USED'
                );
            }

            $deviceDbId = (int) $codeRow['device_db_id'];

            // Upsert dashboard_device_pairings for (session_id, device_id)
            $checkPair = $db->prepare('
                SELECT id FROM dashboard_device_pairings
                WHERE session_id = ? AND device_id = ?
                LIMIT 1
            ');
            $checkPair->execute([$sessionId, $deviceDbId]);
            $existingPair = $checkPair->fetch();

            if ($existingPair) {
                $updPair = $db->prepare('
                    UPDATE dashboard_device_pairings
                    SET paired_at = ?,
                        revoked_at = NULL,
                        revoked_by = NULL,
                        revocation_acknowledged_at = NULL
                    WHERE id = ?
                ');
                $updPair->execute([$nowUtc, (int) $existingPair['id']]);
            } else {
                $insPair = $db->prepare('
                    INSERT INTO dashboard_device_pairings (
                        session_id, device_id, paired_at, revoked_at, revoked_by, revocation_acknowledged_at
                    ) VALUES (?, ?, ?, NULL, NULL, NULL)
                ');
                $insPair->execute([$sessionId, $deviceDbId, $nowUtc]);
            }

            // Transition status_state from waiting_for_pairing -> registered if not actively sharing
            $updStatus = $db->prepare('
                UPDATE device_status
                SET status_state = CASE
                        WHEN status_state = \'waiting_for_pairing\' THEN \'registered\'
                        ELSE status_state
                    END,
                    updated_at = ?
                WHERE device_id = ?
            ');
            $updStatus->execute([$nowUtc, $deviceDbId]);

            $db->commit();

            $devicesData = self::getPairedDevicesForDashboard($sessionId);
            $pairedDevice = null;
            foreach ($devicesData['devices'] as $dev) {
                if ($dev['device_id'] === $codeRow['public_device_id']) {
                    $pairedDevice = $dev;
                    break;
                }
            }

            return [
                'message' => 'Phone paired with this laptop dashboard.',
                'device'  => $pairedDevice,
            ];
        } catch (ResponseTerminateException $re) {
            throw $re;
        } catch (Throwable $e) {
            if ($db->inTransaction()) {
                $db->rollBack();
            }
            Security::logError('pairDashboardSession failed', $e);
            Response::error('Failed to complete pairing.', 500, 'PAIR_FAILED');
        }
    }

    /**
     * Record a phone heartbeat and operational state without overwriting location fix coordinates/time.
     */
    public static function recordHeartbeat(int $deviceDbId, array $payload): array
    {
        $db = Database::getConnection();
        $now = time();
        $nowUtc = gmdate('Y-m-d H:i:s', $now);

        $currentStmt = $db->prepare('
            SELECT sharing_enabled, status_state, presence_mode, current_place_id,
                   current_place_name, smart_home_mode,
                   battery_percentage, is_charging, network_status
            FROM device_status
            WHERE device_id = ?
            LIMIT 1
        ');
        $currentStmt->execute([$deviceDbId]);
        $current = $currentStmt->fetch() ?: [
            'sharing_enabled'    => 0,
            'status_state'       => 'registered',
            'presence_mode'      => 'unknown',
            'current_place_id'   => null,
            'current_place_name' => null,
            'smart_home_mode'    => 1,
            'battery_percentage' => null,
            'is_charging'        => null,
            'network_status'     => 'unknown',
        ];

        $pairedCount = self::countActivePairings($db, $deviceDbId);

        $sharingEnabled = array_key_exists('sharing_enabled', $payload)
            ? ((bool) $payload['sharing_enabled'] ? 1 : 0)
            : (int) $current['sharing_enabled'];

        $defaultState = $sharingEnabled ? 'sharing' : ($pairedCount > 0 ? 'paused' : 'waiting_for_pairing');
        $statusState = isset($payload['status_state'])
            ? Security::validateStatusState($payload['status_state'], $defaultState)
            : ($sharingEnabled ? 'sharing' : (string) $current['status_state']);

        // If not sharing and not paired, reflect waiting_for_pairing unless permission_missing
        if (!$sharingEnabled && $pairedCount === 0 && !in_array($statusState, ['permission_missing', 'offline'], true)) {
            $statusState = 'waiting_for_pairing';
        } elseif (!$sharingEnabled && $pairedCount > 0 && $statusState === 'waiting_for_pairing') {
            $statusState = 'registered';
        }

        $presenceMode = array_key_exists('presence_mode', $payload) && $payload['presence_mode'] !== null
            ? Security::validatePresenceMode($payload['presence_mode'], (string) ($current['presence_mode'] ?? 'unknown'))
            : (string) ($current['presence_mode'] ?? 'unknown');
        $currentPlaceId = array_key_exists('current_place_id', $payload)
            ? (Security::isValidIdentifier($payload['current_place_id']) ? trim((string) $payload['current_place_id']) : null)
            : $current['current_place_id'];
        $currentPlaceName = array_key_exists('current_place_name', $payload)
            ? ($payload['current_place_name'] !== null && trim((string) $payload['current_place_name']) !== ''
                ? Security::sanitizeDeviceName($payload['current_place_name'], '')
                : null)
            : $current['current_place_name'];
        $smartHomeMode = array_key_exists('smart_home_mode', $payload) && $payload['smart_home_mode'] !== null
            ? ((bool) $payload['smart_home_mode'] ? 1 : 0)
            : (int) ($current['smart_home_mode'] ?? 1);

        $battery = array_key_exists('battery', $payload) && $payload['battery'] !== null
            ? min(100, max(0, (int) $payload['battery']))
            : $current['battery_percentage'];

        $isCharging = array_key_exists('is_charging', $payload) && $payload['is_charging'] !== null
            ? ((bool) $payload['is_charging'] ? 1 : 0)
            : $current['is_charging'];

        $network = isset($payload['network_type']) && is_string($payload['network_type']) && trim($payload['network_type']) !== ''
            ? substr(trim($payload['network_type']), 0, 20)
            : (string) ($current['network_status'] ?? 'unknown');

        // Optional device_name update
        if (!empty($payload['device_name']) && is_string($payload['device_name'])) {
            $cleanName = Security::sanitizeDeviceName($payload['device_name']);
            $updName = $db->prepare('UPDATE devices SET device_name = ?, updated_at = ? WHERE id = ?');
            $updName->execute([$cleanName, $nowUtc, $deviceDbId]);
        }

        $upd = $db->prepare('
            UPDATE device_status
            SET sharing_enabled    = ?,
                status_state       = ?,
                presence_mode      = ?,
                current_place_id   = ?,
                current_place_name = ?,
                smart_home_mode    = ?,
                battery_percentage = ?,
                is_charging        = ?,
                network_status     = ?,
                last_heartbeat_at  = ?,
                updated_at         = ?
            WHERE device_id = ?
        ');
        $upd->execute([
            $sharingEnabled,
            $statusState,
            $presenceMode,
            $currentPlaceId,
            $currentPlaceName,
            $smartHomeMode,
            $battery,
            $isCharging,
            $network,
            $nowUtc,
            $nowUtc,
            $deviceDbId,
        ]);

        return self::getDeviceStatusForPhone($deviceDbId);
    }

    /**
     * Validate and store the phone's newest location fix (latest-only storage).
     */
    public static function updateLocation(int $deviceDbId, array $payload): array
    {
        $coordCheck = Security::validateCoordinates(
            $payload['latitude'] ?? null,
            $payload['longitude'] ?? null
        );
        if (!$coordCheck['valid']) {
            Response::error($coordCheck['error'], 400, 'INVALID_COORDINATES');
        }

        $accCheck = Security::validateAccuracy($payload['accuracy'] ?? null);
        if (!$accCheck['valid']) {
            Response::error($accCheck['error'], 400, 'INVALID_ACCURACY');
        }

        $rawTimestamp = $payload['timestamp'] ?? $payload['recorded_at'] ?? null;
        $tsCheck = Security::validateTimestamp($rawTimestamp);
        if (!$tsCheck['valid']) {
            Response::error($tsCheck['error'], 400, 'INVALID_TIMESTAMP');
        }

        $latitude     = $coordCheck['latitude'];
        $longitude    = $coordCheck['longitude'];
        $accuracy     = $accCheck['accuracy'];
        $recordedUtc  = $tsCheck['utc_datetime'];
        $recordedEpoch = $tsCheck['timestamp'];

        $battery = isset($payload['battery']) && is_numeric($payload['battery'])
            ? min(100, max(0, (int) $payload['battery']))
            : null;
        $isCharging = isset($payload['is_charging'])
            ? ((bool) $payload['is_charging'] ? 1 : 0)
            : null;
        $network = isset($payload['network_type']) && is_string($payload['network_type']) && trim($payload['network_type']) !== ''
            ? substr(trim($payload['network_type']), 0, 20)
            : null;

        $presenceMode = Security::validatePresenceMode($payload['presence_mode'] ?? null, 'away');
        $currentPlaceId = isset($payload['current_place_id']) && Security::isValidIdentifier($payload['current_place_id'])
            ? trim((string) $payload['current_place_id'])
            : null;
        $currentPlaceName = isset($payload['current_place_name']) && is_string($payload['current_place_name']) && trim($payload['current_place_name']) !== ''
            ? Security::sanitizeDeviceName($payload['current_place_name'], '')
            : null;
        $homePrivacyMasked = !empty($payload['home_privacy_masked']) ? 1 : 0;
        $smartHomeMode = array_key_exists('smart_home_mode', $payload)
            ? ((bool) $payload['smart_home_mode'] ? 1 : 0)
            : null;
        $speedMps = isset($payload['speed_mps']) && is_numeric($payload['speed_mps']) && !is_bool($payload['speed_mps'])
            ? max(0.0, min(200.0, round((float) $payload['speed_mps'], 2)))
            : null;

        $now = time();
        $nowUtc = gmdate('Y-m-d H:i:s', $now);

        $db = Database::getConnection();
        $db->beginTransaction();

        try {
            // Look up active family circle & saved places for Home privacy enforcement and sync
            $circleStmt = $db->prepare('
                SELECT circle_id FROM circle_members
                WHERE device_id = ? AND left_at IS NULL
                ORDER BY joined_at DESC
                LIMIT 1
            ');
            $circleStmt->execute([$deviceDbId]);
            $circleRow = $circleStmt->fetch();
            $circlePlaces = [];

            if ($circleRow) {
                $placesStmt = $db->prepare('
                    SELECT place_id, name, category, latitude, longitude, radius_meters,
                           is_home, notify_on_enter, notify_on_exit
                    FROM saved_places
                    WHERE circle_id = ? AND deleted_at IS NULL
                    ORDER BY is_home DESC, created_at ASC
                ');
                $placesStmt->execute([(int) $circleRow['circle_id']]);
                foreach ($placesStmt->fetchAll() as $pRow) {
                    $placeItem = [
                        'place_id'        => (string) $pRow['place_id'],
                        'name'            => (string) $pRow['name'],
                        'category'        => (string) $pRow['category'],
                        'latitude'        => (float) $pRow['latitude'],
                        'longitude'       => (float) $pRow['longitude'],
                        'radius_meters'   => (int) $pRow['radius_meters'],
                        'is_home'         => (bool) $pRow['is_home'],
                        'notify_on_enter' => (bool) $pRow['notify_on_enter'],
                        'notify_on_exit'  => (bool) $pRow['notify_on_exit'],
                    ];
                    $circlePlaces[] = $placeItem;
                    if ($homePrivacyMasked === 1 && $presenceMode === 'at_home' && $placeItem['is_home']) {
                        // Server-side Home privacy enforcement: store Home center instead of indoor GPS jitter
                        $latitude = $placeItem['latitude'];
                        $longitude = $placeItem['longitude'];
                        $currentPlaceId = $currentPlaceId ?? $placeItem['place_id'];
                        $currentPlaceName = $currentPlaceName ?? $placeItem['name'];
                        $speedMps = 0.0;
                    }
                }
            }

            $curStmt = $db->prepare('
                SELECT location_recorded_at, battery_percentage, is_charging, network_status, smart_home_mode
                FROM device_status
                WHERE device_id = ?
                LIMIT 1
            ');
            $curStmt->execute([$deviceDbId]);
            $current = $curStmt->fetch();

            $existingEpoch = null;
            if ($current && !empty($current['location_recorded_at'])) {
                $existingEpoch = strtotime((string) $current['location_recorded_at'] . ' UTC') ?: null;
            }

            $finalBattery  = $battery !== null ? $battery : ($current['battery_percentage'] ?? null);
            $finalCharging = $isCharging !== null ? $isCharging : ($current['is_charging'] ?? null);
            $finalNetwork  = $network !== null ? $network : ($current['network_status'] ?? 'unknown');
            $finalSmartHome = $smartHomeMode !== null ? $smartHomeMode : (int) ($current['smart_home_mode'] ?? 1);

            $ignoredOlderFix = false;
            if ($existingEpoch !== null && $recordedEpoch < $existingEpoch) {
                // Do not overwrite a newer stored location fix with an older out-of-order point
                $ignoredOlderFix = true;
                $upd = $db->prepare('
                    UPDATE device_status
                    SET sharing_enabled    = 1,
                        status_state       = \'sharing\',
                        battery_percentage = ?,
                        is_charging        = ?,
                        network_status     = ?,
                        last_heartbeat_at  = ?,
                        updated_at         = ?
                    WHERE device_id = ?
                ');
                $upd->execute([
                    $finalBattery,
                    $finalCharging,
                    $finalNetwork,
                    $nowUtc,
                    $nowUtc,
                    $deviceDbId,
                ]);
            } else {
                // Latest-only location update
                $upd = $db->prepare('
                    UPDATE device_status
                    SET sharing_enabled      = 1,
                        status_state         = \'sharing\',
                        presence_mode        = ?,
                        current_place_id     = ?,
                        current_place_name   = ?,
                        home_privacy_masked  = ?,
                        smart_home_mode      = ?,
                        speed_mps            = ?,
                        battery_percentage   = ?,
                        is_charging          = ?,
                        network_status       = ?,
                        last_latitude        = ?,
                        last_longitude       = ?,
                        last_accuracy        = ?,
                        location_recorded_at = ?,
                        location_received_at = ?,
                        last_heartbeat_at    = ?,
                        updated_at           = ?
                    WHERE device_id = ?
                ');
                $upd->execute([
                    $presenceMode,
                    $currentPlaceId,
                    $currentPlaceName,
                    $homePrivacyMasked,
                    $finalSmartHome,
                    $speedMps,
                    $finalBattery,
                    $finalCharging,
                    $finalNetwork,
                    $latitude,
                    $longitude,
                    $accuracy,
                    $recordedUtc,
                    $nowUtc,
                    $nowUtc,
                    $nowUtc,
                    $deviceDbId,
                ]);
            }

            $pairedCount = self::countActivePairings($db, $deviceDbId);
            $db->commit();

            return [
                'message'                 => $ignoredOlderFix
                    ? 'Heartbeat updated; older location fix ignored in favor of newer stored fix.'
                    : 'Latest location recorded.',
                'ignored_older_fix'       => $ignoredOlderFix,
                'recorded_at'             => gmdate('Y-m-d\TH:i:s\Z', $ignoredOlderFix && $existingEpoch ? $existingEpoch : $recordedEpoch),
                'received_at'             => gmdate('Y-m-d\TH:i:s\Z', $now),
                'paired_dashboards_count' => $pairedCount,
                'status_state'            => 'sharing',
                'presence_mode'           => $presenceMode,
                'home_privacy_masked'     => (bool) $homePrivacyMasked,
                'places'                  => $circlePlaces,
            ];
        } catch (Throwable $e) {
            if ($db->inTransaction()) {
                $db->rollBack();
            }
            Security::logError('updateLocation failed', $e);
            Response::error('Failed to save location.', 500, 'LOCATION_UPDATE_FAILED');
        }
    }

    /**
     * Delete the stored location for a device (invoked by phone owner or paired dashboard).
     */
    public static function deleteLocation(int $deviceDbId): array
    {
        $db = Database::getConnection();
        $nowUtc = gmdate('Y-m-d H:i:s');

        $stmt = $db->prepare('
            UPDATE device_status
            SET last_latitude        = NULL,
                last_longitude       = NULL,
                last_accuracy        = NULL,
                location_recorded_at = NULL,
                location_received_at = NULL,
                presence_mode        = \'unknown\',
                current_place_id     = NULL,
                current_place_name   = NULL,
                home_privacy_masked  = 0,
                speed_mps            = NULL,
                updated_at           = ?
            WHERE device_id = ?
        ');
        $stmt->execute([$nowUtc, $deviceDbId]);

        return [
            'message'          => 'Stored location deleted.',
            'location_deleted' => true,
            'deleted_at'       => gmdate('Y-m-d\TH:i:s\Z'),
        ];
    }

    /**
     * Revoke all dashboard pairings for a phone (phone owner action).
     */
    public static function unpairAllDashboards(int $deviceDbId, bool $clearLocation = true): array
    {
        $db = Database::getConnection();
        $nowUtc = gmdate('Y-m-d H:i:s');

        $db->beginTransaction();
        try {
            $stmtPair = $db->prepare('
                UPDATE dashboard_device_pairings
                SET revoked_at = ?,
                    revoked_by = \'phone\',
                    revocation_acknowledged_at = NULL
                WHERE device_id = ? AND revoked_at IS NULL
            ');
            $stmtPair->execute([$nowUtc, $deviceDbId]);
            $revokedCount = $stmtPair->rowCount();

            $stmtCodes = $db->prepare('
                UPDATE pairing_codes
                SET revoked_at = ?
                WHERE device_id = ? AND used_at IS NULL AND revoked_at IS NULL
            ');
            $stmtCodes->execute([$nowUtc, $deviceDbId]);

            if ($clearLocation) {
                $stmtStatus = $db->prepare('
                    UPDATE device_status
                    SET sharing_enabled      = 0,
                        status_state         = \'waiting_for_pairing\',
                        last_latitude        = NULL,
                        last_longitude       = NULL,
                        last_accuracy        = NULL,
                        location_recorded_at = NULL,
                        location_received_at = NULL,
                        last_heartbeat_at    = ?,
                        updated_at           = ?
                    WHERE device_id = ?
                ');
                $stmtStatus->execute([$nowUtc, $nowUtc, $deviceDbId]);
            } else {
                $stmtStatus = $db->prepare('
                    UPDATE device_status
                    SET sharing_enabled   = 0,
                        status_state      = \'waiting_for_pairing\',
                        last_heartbeat_at = ?,
                        updated_at        = ?
                    WHERE device_id = ?
                ');
                $stmtStatus->execute([$nowUtc, $nowUtc, $deviceDbId]);
            }

            $db->commit();

            return [
                'message'           => 'All dashboard pairings have been revoked.',
                'revoked_pairings'  => $revokedCount,
                'location_cleared'  => $clearLocation,
                'status_state'      => 'waiting_for_pairing',
                'sharing_enabled'   => false,
            ];
        } catch (Throwable $e) {
            if ($db->inTransaction()) {
                $db->rollBack();
            }
            Security::logError('unpairAllDashboards failed', $e);
            Response::error('Failed to revoke dashboard pairings.', 500, 'UNPAIR_FAILED');
        }
    }

    /**
     * Unregister a phone completely, invalidating its token, revoking all pairings, and wiping location.
     */
    public static function unregisterDevice(int $deviceDbId): array
    {
        $db = Database::getConnection();
        $nowUtc = gmdate('Y-m-d H:i:s');
        $invalidatedHash = 'REVOKED_' . Security::generateToken(16);

        $db->beginTransaction();
        try {
            $stmtDev = $db->prepare('
                UPDATE devices
                SET unregistered_at = ?,
                    token_hash      = ?,
                    updated_at      = ?
                WHERE id = ?
            ');
            $stmtDev->execute([$nowUtc, $invalidatedHash, $nowUtc, $deviceDbId]);

            $stmtPair = $db->prepare('
                UPDATE dashboard_device_pairings
                SET revoked_at = ?,
                    revoked_by = \'unregister\',
                    revocation_acknowledged_at = NULL
                WHERE device_id = ? AND revoked_at IS NULL
            ');
            $stmtPair->execute([$nowUtc, $deviceDbId]);

            $stmtCodes = $db->prepare('
                UPDATE pairing_codes
                SET revoked_at = ?
                WHERE device_id = ? AND used_at IS NULL AND revoked_at IS NULL
            ');
            $stmtCodes->execute([$nowUtc, $deviceDbId]);

            $stmtStatus = $db->prepare('
                UPDATE device_status
                SET sharing_enabled      = 0,
                    status_state         = \'unregistered\',
                    presence_mode        = \'unknown\',
                    current_place_id     = NULL,
                    current_place_name   = NULL,
                    home_privacy_masked  = 0,
                    speed_mps            = NULL,
                    last_latitude        = NULL,
                    last_longitude       = NULL,
                    last_accuracy        = NULL,
                    location_recorded_at = NULL,
                    location_received_at = NULL,
                    updated_at           = ?
                WHERE device_id = ?
            ');
            $stmtStatus->execute([$nowUtc, $deviceDbId]);

            $stmtCircle = $db->prepare('
                UPDATE circle_members
                SET left_at = ?
                WHERE device_id = ? AND left_at IS NULL
            ');
            $stmtCircle->execute([$nowUtc, $deviceDbId]);

            $stmtPush = $db->prepare('DELETE FROM push_tokens WHERE device_id = ?');
            $stmtPush->execute([$deviceDbId]);

            $db->commit();

            return [
                'message'           => 'Device unregistered and stored location deleted.',
                'unregistered'      => true,
                'location_deleted'  => true,
                'unregistered_at'   => gmdate('Y-m-d\TH:i:s\Z'),
            ];
        } catch (Throwable $e) {
            if ($db->inTransaction()) {
                $db->rollBack();
            }
            Security::logError('unregisterDevice failed', $e);
            Response::error('Failed to unregister device.', 500, 'UNREGISTER_FAILED');
        }
    }

    /**
     * Get the current status of a device for the authenticated phone owner.
     */
    public static function getDeviceStatusForPhone(int $deviceDbId): array
    {
        $db = Database::getConnection();
        $stmt = $db->prepare('
            SELECT
                d.device_id,
                d.device_name,
                d.registered_at,
                ds.sharing_enabled,
                ds.status_state,
                ds.presence_mode,
                ds.current_place_id,
                ds.current_place_name,
                ds.home_privacy_masked,
                ds.smart_home_mode,
                ds.speed_mps,
                ds.battery_percentage,
                ds.is_charging,
                ds.network_status,
                ds.last_latitude,
                ds.last_longitude,
                ds.last_accuracy,
                ds.location_recorded_at,
                ds.location_received_at,
                ds.last_heartbeat_at
            FROM devices d
            JOIN device_status ds ON ds.device_id = d.id
            WHERE d.id = ? AND d.unregistered_at IS NULL
            LIMIT 1
        ');
        $stmt->execute([$deviceDbId]);
        $row = $stmt->fetch();

        if (!$row) {
            Response::error('Device not found.', 404, 'DEVICE_NOT_FOUND');
        }

        $pairedCount = self::countActivePairings($db, $deviceDbId);

        // Check if there is an active unused pairing code
        $nowUtc = gmdate('Y-m-d H:i:s');
        $codeStmt = $db->prepare('
            SELECT expires_at
            FROM pairing_codes
            WHERE device_id = ? AND used_at IS NULL AND revoked_at IS NULL AND expires_at > ?
            ORDER BY id DESC
            LIMIT 1
        ');
        $codeStmt->execute([$deviceDbId, $nowUtc]);
        $activeCode = $codeStmt->fetch();

        $hasLocation = $row['last_latitude'] !== null && $row['last_longitude'] !== null;

        return [
            'device_id'               => (string) $row['device_id'],
            'device_name'             => (string) $row['device_name'],
            'sharing_enabled'         => (bool) $row['sharing_enabled'],
            'status_state'            => (string) $row['status_state'],
            'presence_mode'           => (string) ($row['presence_mode'] ?? 'unknown'),
            'current_place_id'        => $row['current_place_id'],
            'current_place_name'      => $row['current_place_name'],
            'home_privacy_masked'     => (bool) ($row['home_privacy_masked'] ?? false),
            'smart_home_mode'         => (bool) ($row['smart_home_mode'] ?? true),
            'paired_dashboards_count' => $pairedCount,
            'has_active_pairing'      => $pairedCount > 0,
            'has_active_pairing_code' => (bool) $activeCode,
            'pairing_code_expires_at' => $activeCode ? self::toIsoUtc((string) $activeCode['expires_at']) : null,
            'has_stored_location'     => $hasLocation,
            'last_accuracy'           => $row['last_accuracy'] !== null ? (float) $row['last_accuracy'] : null,
            'location_recorded_at'    => self::toIsoUtc($row['location_recorded_at']),
            'location_received_at'    => self::toIsoUtc($row['location_received_at']),
            'last_heartbeat_at'       => self::toIsoUtc($row['last_heartbeat_at']),
        ];
    }

    /**
     * Retrieve all paired devices and any unacknowledged revoked pairings for a dashboard session.
     * Enforces strict isolation: a dashboard session can read ONLY devices paired to it.
     */
    public static function getPairedDevicesForDashboard(int $sessionId): array
    {
        $config = require __DIR__ . '/../config/app.php';
        $onlineThreshold = max(15, (int) ($config['status']['online_threshold_seconds'] ?? 90));
        $staleThreshold  = max(30, (int) ($config['status']['location_stale_seconds'] ?? 180));

        $db = Database::getConnection();
        $now = time();

        $stmt = $db->prepare('
            SELECT
                d.id AS device_db_id,
                d.device_id,
                d.device_name,
                d.registered_at,
                ddp.paired_at,
                ds.sharing_enabled,
                ds.status_state,
                ds.presence_mode,
                ds.current_place_id,
                ds.current_place_name,
                ds.home_privacy_masked,
                ds.smart_home_mode,
                ds.speed_mps,
                ds.battery_percentage,
                ds.is_charging,
                ds.network_status,
                ds.last_latitude,
                ds.last_longitude,
                ds.last_accuracy,
                ds.location_recorded_at,
                ds.location_received_at,
                ds.last_heartbeat_at,
                ds.updated_at
            FROM dashboard_device_pairings ddp
            JOIN devices d ON d.id = ddp.device_id
            JOIN device_status ds ON ds.device_id = d.id
            WHERE ddp.session_id = ?
              AND ddp.revoked_at IS NULL
              AND d.unregistered_at IS NULL
            ORDER BY ddp.paired_at DESC, d.id DESC
        ');
        $stmt->execute([$sessionId]);
        $rows = $stmt->fetchAll();

        $devices = [];
        foreach ($rows as $row) {
            $devices[] = self::formatDeviceForDashboard($row, $now, $onlineThreshold, $staleThreshold);
        }

        // Also fetch unacknowledged revoked pairings (metadata only, NEVER location!)
        $revStmt = $db->prepare('
            SELECT
                d.device_id,
                d.device_name,
                ddp.revoked_at,
                ddp.revoked_by
            FROM dashboard_device_pairings ddp
            JOIN devices d ON d.id = ddp.device_id
            WHERE ddp.session_id = ?
              AND ddp.revoked_at IS NOT NULL
              AND ddp.revocation_acknowledged_at IS NULL
            ORDER BY ddp.revoked_at DESC
        ');
        $revStmt->execute([$sessionId]);
        $revokedRows = $revStmt->fetchAll();

        $revokedNotices = [];
        foreach ($revokedRows as $rev) {
            $revokedNotices[] = [
                'device_id'   => (string) $rev['device_id'],
                'device_name' => (string) $rev['device_name'],
                'revoked_at'  => self::toIsoUtc($rev['revoked_at']),
                'revoked_by'  => (string) ($rev['revoked_by'] ?? 'phone'),
            ];
        }

        return [
            'devices'          => $devices,
            'revoked_pairings' => $revokedNotices,
            'thresholds'       => [
                'online_threshold_seconds' => $onlineThreshold,
                'location_stale_seconds'   => $staleThreshold,
            ],
            'server_time'      => gmdate('Y-m-d\TH:i:s\Z', $now),
        ];
    }

    /**
     * Unpair a device from the current dashboard session (or acknowledge a phone-revoked pairing).
     */
    public static function unpairDeviceFromDashboard(
        int $sessionId,
        string $publicDeviceId,
        bool $deleteLocation = false,
        bool $acknowledgeOnly = false
    ): array {
        if (!Security::isValidDeviceId($publicDeviceId)) {
            Response::error('Invalid device identifier.', 400, 'INVALID_DEVICE_ID');
        }

        $db = Database::getConnection();
        $nowUtc = gmdate('Y-m-d H:i:s');

        $stmt = $db->prepare('
            SELECT ddp.id AS pairing_id, ddp.revoked_at, d.id AS device_db_id, d.device_name
            FROM dashboard_device_pairings ddp
            JOIN devices d ON d.id = ddp.device_id
            WHERE ddp.session_id = ? AND d.device_id = ?
            LIMIT 1
        ');
        $stmt->execute([$sessionId, $publicDeviceId]);
        $row = $stmt->fetch();

        if (!$row) {
            Response::error('Device is not paired with this dashboard session.', 404, 'NOT_PAIRED');
        }

        $deviceDbId = (int) $row['device_db_id'];

        $db->beginTransaction();
        try {
            if ($row['revoked_at'] !== null || $acknowledgeOnly) {
                $upd = $db->prepare('
                    UPDATE dashboard_device_pairings
                    SET revocation_acknowledged_at = ?
                    WHERE id = ?
                ');
                $upd->execute([$nowUtc, (int) $row['pairing_id']]);
            } else {
                $upd = $db->prepare('
                    UPDATE dashboard_device_pairings
                    SET revoked_at = ?,
                        revoked_by = \'dashboard\',
                        revocation_acknowledged_at = ?
                    WHERE id = ?
                ');
                $upd->execute([$nowUtc, $nowUtc, (int) $row['pairing_id']]);

                if ($deleteLocation) {
                    self::deleteLocation($deviceDbId);
                }

                // If no remaining active pairings and not sharing, update status_state
                $remaining = self::countActivePairings($db, $deviceDbId);
                if ($remaining === 0) {
                    $updSt = $db->prepare('
                        UPDATE device_status
                        SET sharing_enabled = 0,
                            status_state    = \'waiting_for_pairing\',
                            updated_at      = ?
                        WHERE device_id = ?
                    ');
                    $updSt->execute([$nowUtc, $deviceDbId]);
                }
            }

            $db->commit();

            return [
                'message'          => 'Device unpaired from this dashboard.',
                'device_id'        => $publicDeviceId,
                'location_deleted' => $deleteLocation,
            ];
        } catch (Throwable $e) {
            if ($db->inTransaction()) {
                $db->rollBack();
            }
            Security::logError('unpairDeviceFromDashboard failed', $e);
            Response::error('Failed to unpair device.', 500, 'UNPAIR_FAILED');
        }
    }

    /**
     * Delete a device's stored location from an authorized paired dashboard session.
     */
    public static function deleteLocationFromDashboard(int $sessionId, string $publicDeviceId): array
    {
        if (!Security::isValidDeviceId($publicDeviceId)) {
            Response::error('Invalid device identifier.', 400, 'INVALID_DEVICE_ID');
        }

        $db = Database::getConnection();
        $stmt = $db->prepare('
            SELECT d.id AS device_db_id
            FROM dashboard_device_pairings ddp
            JOIN devices d ON d.id = ddp.device_id
            WHERE ddp.session_id = ?
              AND d.device_id = ?
              AND ddp.revoked_at IS NULL
              AND d.unregistered_at IS NULL
            LIMIT 1
        ');
        $stmt->execute([$sessionId, $publicDeviceId]);
        $row = $stmt->fetch();

        if (!$row) {
            Response::error('Not authorized to modify this device.', 403, 'FORBIDDEN_DEVICE');
        }

        return self::deleteLocation((int) $row['device_db_id']);
    }

    /**
     * Format a paired device row for dashboard consumption, keeping heartbeat online state
     * strictly separate from location-fix freshness.
     */
    public static function formatDeviceForDashboard(
        array $row,
        int $now,
        int $onlineThreshold,
        int $staleThreshold
    ): array {
        // 1. Heartbeat / Connection state
        $heartbeatEpoch = !empty($row['last_heartbeat_at'])
            ? (strtotime((string) $row['last_heartbeat_at'] . ' UTC') ?: null)
            : null;
        $heartbeatAge = $heartbeatEpoch !== null ? max(0, $now - $heartbeatEpoch) : null;

        $reportedState = (string) ($row['status_state'] ?? 'registered');
        $isOnline = ($heartbeatAge !== null)
            && ($heartbeatAge <= $onlineThreshold)
            && ($reportedState !== 'offline');

        $connectionState = $isOnline
            ? 'online'
            : ($heartbeatEpoch !== null ? 'offline' : 'never_connected');

        // 2. Location fix freshness (based strictly on location_recorded_at, NOT last_heartbeat_at!)
        $hasLocation = ($row['last_latitude'] !== null)
            && ($row['last_longitude'] !== null)
            && !empty($row['location_recorded_at']);

        $locationRecordedEpoch = $hasLocation
            ? (strtotime((string) $row['location_recorded_at'] . ' UTC') ?: null)
            : null;
        $locationReceivedEpoch = !empty($row['location_received_at'])
            ? (strtotime((string) $row['location_received_at'] . ' UTC') ?: null)
            : null;

        $locationAge = $locationRecordedEpoch !== null ? max(0, $now - $locationRecordedEpoch) : null;
        $isLocationFresh = $hasLocation && $locationAge !== null && ($locationAge <= $staleThreshold);
        $isLocationStale = $hasLocation && $locationAge !== null && ($locationAge > $staleThreshold);
        $locationState = !$hasLocation
            ? 'no_location'
            : ($isLocationFresh ? 'current' : 'stale');

        // 3. Effective operational state
        $sharingEnabled = (bool) $row['sharing_enabled'];
        $effectiveState = $reportedState;
        if (!$isOnline && $heartbeatEpoch !== null) {
            $effectiveState = 'offline';
        } elseif ($sharingEnabled && !$hasLocation && $effectiveState === 'sharing') {
            $effectiveState = 'no_gps_fix';
        }

        return [
            'device_id'             => (string) $row['device_id'],
            'device_name'           => (string) $row['device_name'],
            'paired_at'             => isset($row['paired_at']) ? self::toIsoUtc($row['paired_at']) : null,
            'sharing_enabled'       => $sharingEnabled,
            'status_state'          => $effectiveState,
            'reported_state'        => $reportedState,
            'presence_mode'         => (string) ($row['presence_mode'] ?? 'unknown'),
            'current_place_id'      => $row['current_place_id'] ?? null,
            'current_place_name'    => $row['current_place_name'] ?? null,
            'home_privacy_masked'   => (bool) ($row['home_privacy_masked'] ?? false),
            'smart_home_mode'       => (bool) ($row['smart_home_mode'] ?? true),
            'speed_mps'             => isset($row['speed_mps']) && $row['speed_mps'] !== null ? (float) $row['speed_mps'] : null,
            'is_online'             => $isOnline,
            'connection_state'      => $connectionState,
            'last_heartbeat_at'     => self::toIsoUtc($row['last_heartbeat_at']),
            'heartbeat_seconds_ago' => $heartbeatAge,
            'battery'               => $row['battery_percentage'] !== null ? (int) $row['battery_percentage'] : null,
            'is_charging'           => $row['is_charging'] !== null ? (bool) $row['is_charging'] : null,
            'network_status'        => (string) ($row['network_status'] ?? 'unknown'),
            'has_location'          => $hasLocation,
            'location_state'        => $locationState,
            'is_location_fresh'     => $isLocationFresh,
            'is_location_stale'     => $isLocationStale,
            'location_age_seconds'  => $locationAge,
            'location'              => $hasLocation ? [
                'latitude'     => (float) $row['last_latitude'],
                'longitude'    => (float) $row['last_longitude'],
                'accuracy'     => $row['last_accuracy'] !== null ? (float) $row['last_accuracy'] : null,
                'recorded_at'  => self::toIsoUtc($row['location_recorded_at']),
                'received_at'  => self::toIsoUtc($row['location_received_at']),
                'age_seconds'  => $locationAge,
                'is_fresh'     => $isLocationFresh,
                'is_stale'     => $isLocationStale,
                'state'        => $locationState,
            ] : null,
        ];
    }

    /**
     * Insert a newly generated pairing code into pairing_codes.
     *
     * @return array{raw: string, formatted: string, expires_utc: string, expires_iso: string, ttl_seconds: int}
     */
    private static function insertPairingCode(PDO $db, int $deviceDbId, array $config): array
    {
        $ttl = max(30, (int) ($config['security']['pairing_code_ttl_seconds'] ?? 300));
        $len = max(8, min(12, (int) ($config['security']['pairing_code_length'] ?? 8)));

        $now = time();
        $nowUtc = gmdate('Y-m-d H:i:s', $now);
        $expiresEpoch = $now + $ttl;
        $expiresUtc = gmdate('Y-m-d H:i:s', $expiresEpoch);
        $expiresIso = gmdate('Y-m-d\TH:i:s\Z', $expiresEpoch);

        $code = null;
        for ($attempt = 0; $attempt < 5; $attempt++) {
            $candidate = Security::generatePairingCode($len);
            $check = $db->prepare('SELECT id FROM pairing_codes WHERE code_hash = ? LIMIT 1');
            $check->execute([$candidate['hash']]);
            if (!$check->fetch()) {
                $code = $candidate;
                break;
            }
        }

        if ($code === null) {
            throw new RuntimeException('Unable to generate unique pairing code.');
        }

        $stmt = $db->prepare('
            INSERT INTO pairing_codes (device_id, code_hash, expires_at, used_at, revoked_at, created_at)
            VALUES (?, ?, ?, NULL, NULL, ?)
        ');
        $stmt->execute([$deviceDbId, $code['hash'], $expiresUtc, $nowUtc]);

        return [
            'raw'         => $code['raw'],
            'formatted'   => $code['formatted'],
            'expires_utc' => $expiresUtc,
            'expires_iso' => $expiresIso,
            'ttl_seconds' => $ttl,
        ];
    }

    /**
     * Count active dashboard pairings for a device.
     */
    private static function countActivePairings(PDO $db, int $deviceDbId): int
    {
        $stmt = $db->prepare('
            SELECT COUNT(*) AS cnt
            FROM dashboard_device_pairings ddp
            JOIN dashboard_sessions ds ON ds.id = ddp.session_id
            WHERE ddp.device_id = ?
              AND ddp.revoked_at IS NULL
              AND ds.expires_at > ?
        ');
        $stmt->execute([$deviceDbId, gmdate('Y-m-d H:i:s')]);
        $row = $stmt->fetch();
        return (int) ($row['cnt'] ?? 0);
    }

    /**
     * Convert a database UTC datetime ('Y-m-d H:i:s') to ISO-8601 ('Y-m-d\TH:i:s\Z').
     */
    public static function toIsoUtc(?string $dbDateTime): ?string
    {
        if ($dbDateTime === null || trim($dbDateTime) === '') {
            return null;
        }
        $ts = strtotime($dbDateTime . ' UTC');
        if ($ts === false) {
            return null;
        }
        return gmdate('Y-m-d\TH:i:s\Z', $ts);
    }
}
