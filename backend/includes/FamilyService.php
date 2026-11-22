<?php
/**
 * LocaShare - Family Circles, Saved Places & Geofence Events Service
 *
 * Implements Life360-style family circles joined via shareable invite codes,
 * Saved Places (Home, School, Work, Custom), Home geofence presence,
 * enter/exit place activity events, optional FCM push relay, and dashboard circle views.
 */

require_once __DIR__ . '/Database.php';
require_once __DIR__ . '/DeviceService.php';
require_once __DIR__ . '/FcmNotifier.php';
require_once __DIR__ . '/Response.php';
require_once __DIR__ . '/Security.php';

class FamilyService
{
    private const AVATAR_COLORS = ['#0EA5E9', '#10B981', '#8B5CF6', '#F59E0B', '#EC4899', '#06B6D4'];

    /**
     * Create a new Family Circle and enroll the calling device as admin.
     */
    public static function createCircle(int $deviceDbId, string $rawCircleName, string $rawMemberName = ''): array
    {
        $db = Database::getConnection();
        $nowUtc = gmdate('Y-m-d H:i:s');

        $devStmt = $db->prepare('SELECT id, device_name FROM devices WHERE id = ? AND unregistered_at IS NULL LIMIT 1');
        $devStmt->execute([$deviceDbId]);
        $dev = $devStmt->fetch();
        if (!$dev) {
            Response::error('Device not found.', 404, 'DEVICE_NOT_FOUND');
        }

        $circleName = Security::sanitizeDeviceName($rawCircleName, 'Our Family');
        $memberName = Security::sanitizeDeviceName($rawMemberName !== '' ? $rawMemberName : (string) $dev['device_name'], 'Member');
        $circlePublicId = Security::generateCircleId();
        $invite = self::generateUniqueInvite($db);

        $db->beginTransaction();
        try {
            // Leave any prior active circle cleanly
            $leaveStmt = $db->prepare('UPDATE circle_members SET left_at = ? WHERE device_id = ? AND left_at IS NULL');
            $leaveStmt->execute([$nowUtc, $deviceDbId]);

            $insCircle = $db->prepare('
                INSERT INTO family_circles (circle_id, name, invite_code, invite_code_hash, created_by_device_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            ');
            $insCircle->execute([
                $circlePublicId,
                $circleName,
                $invite['formatted'],
                $invite['hash'],
                $deviceDbId,
                $nowUtc,
                $nowUtc,
            ]);
            $circleDbId = (int) $db->lastInsertId();

            $insMember = $db->prepare('
                INSERT INTO circle_members (circle_id, device_id, member_name, role, avatar_color, joined_at, left_at)
                VALUES (?, ?, ?, \'admin\', ?, ?, NULL)
            ');
            $insMember->execute([$circleDbId, $deviceDbId, $memberName, self::AVATAR_COLORS[0], $nowUtc]);

            $db->commit();
            return self::getCircleSnapshotForDevice($deviceDbId);
        } catch (Throwable $e) {
            if ($db->inTransaction()) {
                $db->rollBack();
            }
            Security::logError('createCircle failed', $e);
            Response::error('Failed to create family circle.', 500, 'CIRCLE_CREATE_FAILED');
        }
    }

    /**
     * Join an existing Family Circle using its invite code (FAM-XXXX-XXXX).
     */
    public static function joinCircle(int $deviceDbId, string $rawInviteCode, string $rawMemberName = ''): array
    {
        $normalized = Security::normalizeInviteCode($rawInviteCode);
        if ($normalized === '' || !preg_match('/^[A-Z0-9]{6,20}$/', $normalized)) {
            Response::error('Invalid family invite code format.', 400, 'INVALID_INVITE_CODE');
        }
        $inviteHash = Security::hashToken($normalized);

        $db = Database::getConnection();
        $nowUtc = gmdate('Y-m-d H:i:s');

        $devStmt = $db->prepare('SELECT id, device_name FROM devices WHERE id = ? AND unregistered_at IS NULL LIMIT 1');
        $devStmt->execute([$deviceDbId]);
        $dev = $devStmt->fetch();
        if (!$dev) {
            Response::error('Device not found.', 404, 'DEVICE_NOT_FOUND');
        }

        $circleStmt = $db->prepare('SELECT id, circle_id, name FROM family_circles WHERE invite_code_hash = ? LIMIT 1');
        $circleStmt->execute([$inviteHash]);
        $circle = $circleStmt->fetch();
        if (!$circle) {
            Response::error('Family invite code not found. Check the code and try again.', 404, 'INVALID_INVITE_CODE');
        }

        $circleDbId = (int) $circle['id'];
        $memberName = Security::sanitizeDeviceName($rawMemberName !== '' ? $rawMemberName : (string) $dev['device_name'], 'Member');
        $color = self::AVATAR_COLORS[$deviceDbId % count(self::AVATAR_COLORS)];

        $db->beginTransaction();
        try {
            $leaveOther = $db->prepare('UPDATE circle_members SET left_at = ? WHERE device_id = ? AND circle_id <> ? AND left_at IS NULL');
            $leaveOther->execute([$nowUtc, $deviceDbId, $circleDbId]);

            $existingStmt = $db->prepare('SELECT id, role FROM circle_members WHERE circle_id = ? AND device_id = ? LIMIT 1');
            $existingStmt->execute([$circleDbId, $deviceDbId]);
            $existing = $existingStmt->fetch();

            if ($existing) {
                $upd = $db->prepare('UPDATE circle_members SET member_name = ?, left_at = NULL, joined_at = ? WHERE id = ?');
                $upd->execute([$memberName, $nowUtc, (int) $existing['id']]);
            } else {
                $ins = $db->prepare('
                    INSERT INTO circle_members (circle_id, device_id, member_name, role, avatar_color, joined_at, left_at)
                    VALUES (?, ?, ?, \'member\', ?, ?, NULL)
                ');
                $ins->execute([$circleDbId, $deviceDbId, $memberName, $color, $nowUtc]);
            }

            $db->commit();
            return self::getCircleSnapshotForDevice($deviceDbId);
        } catch (Throwable $e) {
            if ($db->inTransaction()) {
                $db->rollBack();
            }
            Security::logError('joinCircle failed', $e);
            Response::error('Failed to join family circle.', 500, 'CIRCLE_JOIN_FAILED');
        }
    }

    /**
     * Leave the active Family Circle for a device.
     */
    public static function leaveCircle(int $deviceDbId): array
    {
        $db = Database::getConnection();
        $nowUtc = gmdate('Y-m-d H:i:s');
        $stmt = $db->prepare('UPDATE circle_members SET left_at = ? WHERE device_id = ? AND left_at IS NULL');
        $stmt->execute([$nowUtc, $deviceDbId]);

        return [
            'message' => 'Left family circle.',
            'left'    => true,
        ];
    }

    /**
     * Rotate the Family Circle invite code so old codes stop working.
     */
    public static function regenerateInviteCode(int $deviceDbId): array
    {
        $db = Database::getConnection();
        $membership = self::requireActiveMembership($db, $deviceDbId);
        $circleDbId = (int) $membership['circle_db_id'];

        $invite = self::generateUniqueInvite($db);
        $nowUtc = gmdate('Y-m-d H:i:s');

        $upd = $db->prepare('
            UPDATE family_circles
            SET invite_code = ?, invite_code_hash = ?, updated_at = ?
            WHERE id = ?
        ');
        $upd->execute([$invite['formatted'], $invite['hash'], $nowUtc, $circleDbId]);

        return [
            'invite_code' => $invite['formatted'],
            'circle_id'   => (string) $membership['circle_id'],
        ];
    }

    /**
     * Create or update a Saved Place (Home, School, Work, Custom) in the device's Family Circle.
     */
    public static function upsertSavedPlace(int $deviceDbId, array $payload): array
    {
        $db = Database::getConnection();
        $membership = self::requireActiveMembership($db, $deviceDbId);
        $circleDbId = (int) $membership['circle_db_id'];

        self::performPlaceUpsert($db, $circleDbId, $deviceDbId, $payload);
        return self::getCircleSnapshotForDevice($deviceDbId);
    }

    /**
     * Soft-delete a Saved Place from the device's Family Circle.
     */
    public static function deleteSavedPlace(int $deviceDbId, string $placeId): array
    {
        if (!Security::isValidIdentifier($placeId, 'plc_')) {
            Response::error('Invalid place identifier.', 400, 'INVALID_PLACE_ID');
        }
        $db = Database::getConnection();
        $membership = self::requireActiveMembership($db, $deviceDbId);
        self::performPlaceDelete($db, (int) $membership['circle_db_id'], trim($placeId));

        return self::getCircleSnapshotForDevice($deviceDbId);
    }

    /**
     * Record a place enter/exit event for a member device and dispatch optional FCM alerts.
     */
    public static function reportPlaceEvent(int $deviceDbId, array $payload): array
    {
        $placeId = trim((string) ($payload['place_id'] ?? ''));
        $eventType = strtolower(trim((string) ($payload['event_type'] ?? '')));

        if (!Security::isValidIdentifier($placeId, 'plc_')) {
            Response::error('Invalid place identifier.', 400, 'INVALID_PLACE_ID');
        }
        if (!in_array($eventType, ['entered', 'exited'], true)) {
            Response::error('event_type must be "entered" or "exited".', 400, 'INVALID_EVENT_TYPE');
        }

        $tsCheck = Security::validateTimestamp($payload['occurred_at'] ?? null);
        if (!$tsCheck['valid']) {
            Response::error($tsCheck['error'], 400, 'INVALID_TIMESTAMP');
        }

        $db = Database::getConnection();
        $membership = self::requireActiveMembership($db, $deviceDbId);
        $circleDbId = (int) $membership['circle_db_id'];

        $placeStmt = $db->prepare('
            SELECT place_id, name, category, is_home, notify_on_enter, notify_on_exit
            FROM saved_places
            WHERE circle_id = ? AND place_id = ? AND deleted_at IS NULL
            LIMIT 1
        ');
        $placeStmt->execute([$circleDbId, $placeId]);
        $place = $placeStmt->fetch();
        if (!$place) {
            Response::error('Saved place not found in your family circle.', 404, 'PLACE_NOT_FOUND');
        }

        $occurredUtc = $tsCheck['utc_datetime'];
        $dedupCutoffUtc = gmdate('Y-m-d H:i:s', $tsCheck['timestamp'] - 30);

        $dupStmt = $db->prepare('
            SELECT event_id
            FROM place_events
            WHERE circle_id = ? AND device_id = ? AND place_id = ? AND event_type = ? AND occurred_at >= ?
            ORDER BY id DESC
            LIMIT 1
        ');
        $dupStmt->execute([$circleDbId, $deviceDbId, $placeId, $eventType, $dedupCutoffUtc]);
        $existingDup = $dupStmt->fetch();

        if ($existingDup) {
            return [
                'deduplicated' => true,
                'event_id'     => (string) $existingDup['event_id'],
                'push_sent'    => 0,
            ];
        }

        $eventId = Security::generateEventId();
        $nowUtc = gmdate('Y-m-d H:i:s');

        $ins = $db->prepare('
            INSERT INTO place_events (
                event_id, circle_id, device_id, member_name,
                place_id, place_name, place_category, event_type, occurred_at, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ');
        $ins->execute([
            $eventId,
            $circleDbId,
            $deviceDbId,
            (string) $membership['member_name'],
            (string) $place['place_id'],
            (string) $place['name'],
            (string) $place['category'],
            $eventType,
            $occurredUtc,
            $nowUtc,
        ]);

        // Keep device presence_mode consistent with transition
        if ($eventType === 'entered') {
            $nextPresence = ((bool) $place['is_home'] || $place['category'] === 'home') ? 'at_home' : 'at_place';
            $updStatus = $db->prepare('
                UPDATE device_status
                SET presence_mode = ?, current_place_id = ?, current_place_name = ?, updated_at = ?
                WHERE device_id = ?
            ');
            $updStatus->execute([$nextPresence, (string) $place['place_id'], (string) $place['name'], $nowUtc, $deviceDbId]);
        } else {
            $updStatus = $db->prepare('
                UPDATE device_status
                SET presence_mode = \'away\',
                    current_place_id = NULL,
                    current_place_name = NULL,
                    home_privacy_masked = 0,
                    updated_at = ?
                WHERE device_id = ?
            ');
            $updStatus->execute([$nowUtc, $deviceDbId]);
        }

        // Prune events older than 14 days
        $pruneCutoff = gmdate('Y-m-d H:i:s', time() - (86400 * 14));
        $prune = $db->prepare('DELETE FROM place_events WHERE circle_id = ? AND occurred_at < ?');
        $prune->execute([$circleDbId, $pruneCutoff]);

        $shouldNotify = $eventType === 'entered'
            ? (bool) $place['notify_on_enter']
            : (bool) $place['notify_on_exit'];

        $eventPayload = [
            'event_id'       => $eventId,
            'device_id'      => (string) $membership['device_public_id'],
            'member_name'    => (string) $membership['member_name'],
            'place_id'       => (string) $place['place_id'],
            'place_name'     => (string) $place['name'],
            'place_category' => (string) $place['category'],
            'event_type'     => $eventType,
            'occurred_at'    => DeviceService::toIsoUtc($occurredUtc),
        ];

        $pushSent = 0;
        if ($shouldNotify && FcmNotifier::isConfigured()) {
            $tokStmt = $db->prepare('
                SELECT pt.fcm_token
                FROM circle_members cm
                JOIN push_tokens pt ON pt.device_id = cm.device_id
                WHERE cm.circle_id = ? AND cm.left_at IS NULL AND cm.device_id <> ?
            ');
            $tokStmt->execute([$circleDbId, $deviceDbId]);
            $tokens = $tokStmt->fetchAll(PDO::FETCH_COLUMN);
            if (!empty($tokens)) {
                $pushSent = FcmNotifier::sendPlaceEvent($tokens, $eventPayload);
            }
        }

        return [
            'deduplicated'  => false,
            'should_notify' => $shouldNotify,
            'event'         => $eventPayload,
            'push_sent'     => $pushSent,
        ];
    }

    /**
     * Save or update a device's FCM push token.
     */
    public static function registerPushToken(int $deviceDbId, string $fcmToken, string $platform = 'android'): array
    {
        $clean = trim($fcmToken);
        if ($clean === '' || strlen($clean) > 4096) {
            Response::error('Invalid FCM token.', 400, 'INVALID_PUSH_TOKEN');
        }
        $plat = in_array(strtolower(trim($platform)), ['android', 'ios', 'web'], true)
            ? strtolower(trim($platform))
            : 'android';

        $db = Database::getConnection();
        $nowUtc = gmdate('Y-m-d H:i:s');

        $exists = $db->prepare('SELECT device_id FROM push_tokens WHERE device_id = ? LIMIT 1');
        $exists->execute([$deviceDbId]);
        if ($exists->fetch()) {
            $upd = $db->prepare('UPDATE push_tokens SET fcm_token = ?, platform = ?, updated_at = ? WHERE device_id = ?');
            $upd->execute([$clean, $plat, $nowUtc, $deviceDbId]);
        } else {
            $ins = $db->prepare('INSERT INTO push_tokens (device_id, fcm_token, platform, updated_at) VALUES (?, ?, ?, ?)');
            $ins->execute([$deviceDbId, $clean, $plat, $nowUtc]);
        }

        return ['registered' => true];
    }

    /**
     * Return full Family Circle snapshot (circle info, members, saved places, recent events) for an authenticated device.
     */
    public static function getCircleSnapshotForDevice(int $deviceDbId, ?string $eventsSince = null): array
    {
        $config = require __DIR__ . '/../config/app.php';
        $onlineThreshold = max(15, (int) ($config['status']['online_threshold_seconds'] ?? 90));
        $staleThreshold  = max(30, (int) ($config['status']['location_stale_seconds'] ?? 180));
        $now = time();

        $db = Database::getConnection();
        $stmt = $db->prepare('
            SELECT fc.id AS circle_db_id, fc.circle_id, fc.name, fc.invite_code, fc.created_at,
                   cm.member_name, cm.role
            FROM circle_members cm
            JOIN family_circles fc ON fc.id = cm.circle_id
            WHERE cm.device_id = ? AND cm.left_at IS NULL
            ORDER BY cm.joined_at DESC
            LIMIT 1
        ');
        $stmt->execute([$deviceDbId]);
        $circleRow = $stmt->fetch();

        if (!$circleRow) {
            return [
                'circle'      => null,
                'members'     => [],
                'places'      => [],
                'events'      => [],
                'thresholds'  => [
                    'online_threshold_seconds' => $onlineThreshold,
                    'location_stale_seconds'   => $staleThreshold,
                ],
                'server_time' => gmdate('Y-m-d\TH:i:s\Z', $now),
            ];
        }

        $circleDbId = (int) $circleRow['circle_db_id'];
        $snapshot = self::loadCirclePayload($db, $circleDbId, $deviceDbId, $eventsSince, $now, $onlineThreshold, $staleThreshold);
        $snapshot['circle'] = [
            'circle_id'      => (string) $circleRow['circle_id'],
            'name'           => (string) $circleRow['name'],
            'invite_code'    => (string) $circleRow['invite_code'],
            'my_role'        => (string) $circleRow['role'],
            'my_member_name' => (string) $circleRow['member_name'],
            'created_at'     => DeviceService::toIsoUtc((string) $circleRow['created_at']),
        ];

        return $snapshot;
    }

    /**
     * Join a Family Circle from a web dashboard session using its invite code.
     */
    public static function joinCircleFromDashboard(int $sessionId, string $rawInviteCode): array
    {
        $normalized = Security::normalizeInviteCode($rawInviteCode);
        if ($normalized === '' || !preg_match('/^[A-Z0-9]{6,20}$/', $normalized)) {
            Response::error('Invalid family invite code format.', 400, 'INVALID_INVITE_CODE');
        }
        $inviteHash = Security::hashToken($normalized);

        $db = Database::getConnection();
        $stmt = $db->prepare('SELECT id, circle_id, name FROM family_circles WHERE invite_code_hash = ? LIMIT 1');
        $stmt->execute([$inviteHash]);
        $circle = $stmt->fetch();

        if (!$circle) {
            Response::error('Family invite code not found.', 404, 'INVALID_INVITE_CODE');
        }

        $circleDbId = (int) $circle['id'];
        $nowUtc = gmdate('Y-m-d H:i:s');

        $existing = $db->prepare('SELECT id FROM dashboard_circle_pairings WHERE session_id = ? AND circle_id = ? LIMIT 1');
        $existing->execute([$sessionId, $circleDbId]);
        $row = $existing->fetch();

        if ($row) {
            $upd = $db->prepare('UPDATE dashboard_circle_pairings SET paired_at = ?, revoked_at = NULL WHERE id = ?');
            $upd->execute([$nowUtc, (int) $row['id']]);
        } else {
            $ins = $db->prepare('INSERT INTO dashboard_circle_pairings (session_id, circle_id, paired_at, revoked_at) VALUES (?, ?, ?, NULL)');
            $ins->execute([$sessionId, $circleDbId, $nowUtc]);
        }

        return self::getDashboardFamilyState($sessionId);
    }

    /**
     * Remove a Family Circle from the current dashboard session.
     */
    public static function leaveCircleFromDashboard(int $sessionId, string $circlePublicId): array
    {
        if (!Security::isValidIdentifier($circlePublicId, 'cir_')) {
            Response::error('Invalid circle identifier.', 400, 'INVALID_CIRCLE_ID');
        }

        $db = Database::getConnection();
        $nowUtc = gmdate('Y-m-d H:i:s');

        $stmt = $db->prepare('
            SELECT dcp.id
            FROM dashboard_circle_pairings dcp
            JOIN family_circles fc ON fc.id = dcp.circle_id
            WHERE dcp.session_id = ? AND fc.circle_id = ? AND dcp.revoked_at IS NULL
            LIMIT 1
        ');
        $stmt->execute([$sessionId, $circlePublicId]);
        $row = $stmt->fetch();
        if (!$row) {
            Response::error('Circle is not paired with this dashboard.', 404, 'NOT_PAIRED');
        }

        $upd = $db->prepare('UPDATE dashboard_circle_pairings SET revoked_at = ? WHERE id = ?');
        $upd->execute([$nowUtc, (int) $row['id']]);

        return self::getDashboardFamilyState($sessionId);
    }

    /**
     * Upsert a Saved Place from an authorized dashboard session paired to that circle.
     */
    public static function upsertSavedPlaceFromDashboard(int $sessionId, string $circlePublicId, array $payload): array
    {
        $db = Database::getConnection();
        $circleDbId = self::requireDashboardCircle($db, $sessionId, $circlePublicId);
        self::performPlaceUpsert($db, $circleDbId, null, $payload);
        return self::getDashboardFamilyState($sessionId);
    }

    /**
     * Delete a Saved Place from an authorized dashboard session paired to that circle.
     */
    public static function deleteSavedPlaceFromDashboard(int $sessionId, string $circlePublicId, string $placeId): array
    {
        if (!Security::isValidIdentifier($placeId, 'plc_')) {
            Response::error('Invalid place identifier.', 400, 'INVALID_PLACE_ID');
        }
        $db = Database::getConnection();
        $circleDbId = self::requireDashboardCircle($db, $sessionId, $circlePublicId);
        self::performPlaceDelete($db, $circleDbId, trim($placeId));
        return self::getDashboardFamilyState($sessionId);
    }

    /**
     * Return all Family Circles, members, saved places, and events linked to a dashboard session.
     */
    public static function getDashboardFamilyState(int $sessionId, ?string $eventsSince = null): array
    {
        $config = require __DIR__ . '/../config/app.php';
        $onlineThreshold = max(15, (int) ($config['status']['online_threshold_seconds'] ?? 90));
        $staleThreshold  = max(30, (int) ($config['status']['location_stale_seconds'] ?? 180));
        $now = time();

        $db = Database::getConnection();
        $stmt = $db->prepare('
            SELECT fc.id AS circle_db_id, fc.circle_id, fc.name, fc.invite_code, fc.created_at
            FROM dashboard_circle_pairings dcp
            JOIN family_circles fc ON fc.id = dcp.circle_id
            WHERE dcp.session_id = ? AND dcp.revoked_at IS NULL
            ORDER BY dcp.paired_at DESC
        ');
        $stmt->execute([$sessionId]);
        $circleRows = $stmt->fetchAll();

        $circles = [];
        foreach ($circleRows as $cRow) {
            $circleDbId = (int) $cRow['circle_db_id'];
            $payload = self::loadCirclePayload($db, $circleDbId, null, $eventsSince, $now, $onlineThreshold, $staleThreshold);
            $payload['circle'] = [
                'circle_id'   => (string) $cRow['circle_id'],
                'name'        => (string) $cRow['name'],
                'invite_code' => (string) $cRow['invite_code'],
                'created_at'  => DeviceService::toIsoUtc((string) $cRow['created_at']),
            ];
            $circles[] = $payload;
        }

        return [
            'circles'     => $circles,
            'thresholds'  => [
                'online_threshold_seconds' => $onlineThreshold,
                'location_stale_seconds'   => $staleThreshold,
            ],
            'server_time' => gmdate('Y-m-d\TH:i:s\Z', $now),
        ];
    }

    // ──────────────────────────────────────────────────────────────
    // Internal Helpers
    // ──────────────────────────────────────────────────────────────

    private static function requireActiveMembership(PDO $db, int $deviceDbId): array
    {
        $stmt = $db->prepare('
            SELECT cm.circle_id AS circle_db_id, cm.member_name, cm.role,
                   fc.circle_id, fc.name AS circle_name,
                   d.device_id AS device_public_id
            FROM circle_members cm
            JOIN family_circles fc ON fc.id = cm.circle_id
            JOIN devices d ON d.id = cm.device_id
            WHERE cm.device_id = ? AND cm.left_at IS NULL AND d.unregistered_at IS NULL
            ORDER BY cm.joined_at DESC
            LIMIT 1
        ');
        $stmt->execute([$deviceDbId]);
        $row = $stmt->fetch();
        if (!$row) {
            Response::error('Device is not in an active family circle.', 409, 'NOT_IN_CIRCLE');
        }
        return $row;
    }

    private static function requireDashboardCircle(PDO $db, int $sessionId, string $circlePublicId): int
    {
        if (!Security::isValidIdentifier($circlePublicId, 'cir_')) {
            Response::error('Invalid circle identifier.', 400, 'INVALID_CIRCLE_ID');
        }
        $stmt = $db->prepare('
            SELECT fc.id
            FROM dashboard_circle_pairings dcp
            JOIN family_circles fc ON fc.id = dcp.circle_id
            WHERE dcp.session_id = ? AND fc.circle_id = ? AND dcp.revoked_at IS NULL
            LIMIT 1
        ');
        $stmt->execute([$sessionId, $circlePublicId]);
        $row = $stmt->fetch();
        if (!$row) {
            Response::error('Not authorized to access this family circle.', 403, 'FORBIDDEN_CIRCLE');
        }
        return (int) $row['id'];
    }

    private static function performPlaceUpsert(PDO $db, int $circleDbId, ?int $actorDeviceDbId, array $payload): void
    {
        $coordCheck = Security::validateCoordinates($payload['latitude'] ?? null, $payload['longitude'] ?? null);
        if (!$coordCheck['valid']) {
            Response::error($coordCheck['error'], 400, 'INVALID_COORDINATES');
        }

        $category = Security::validatePlaceCategory($payload['category'] ?? null, 'custom');
        $isHome = !empty($payload['is_home']) || $category === 'home';
        if ($isHome) {
            $category = 'home';
        }

        $defaultName = $isHome ? 'Home' : ucfirst($category);
        $name = Security::sanitizeDeviceName($payload['name'] ?? $defaultName, $defaultName);
        $radiusMeters = Security::validateRadiusMeters($payload['radius_meters'] ?? 150, 150);
        $notifyEnter = array_key_exists('notify_on_enter', $payload) ? (!empty($payload['notify_on_enter']) ? 1 : 0) : 1;
        $notifyExit = array_key_exists('notify_on_exit', $payload) ? (!empty($payload['notify_on_exit']) ? 1 : 0) : 1;

        $requestedPlaceId = isset($payload['place_id']) && is_string($payload['place_id'])
            ? trim($payload['place_id'])
            : '';
        if ($requestedPlaceId !== '' && !Security::isValidIdentifier($requestedPlaceId, 'plc_')) {
            Response::error('Invalid place identifier.', 400, 'INVALID_PLACE_ID');
        }

        $nowUtc = gmdate('Y-m-d H:i:s');
        $db->beginTransaction();
        try {
            $placeId = $requestedPlaceId !== '' ? $requestedPlaceId : Security::generatePlaceId();

            if ($isHome) {
                $clearHome = $db->prepare('
                    UPDATE saved_places
                    SET is_home = 0, updated_at = ?
                    WHERE circle_id = ? AND is_home = 1 AND deleted_at IS NULL AND place_id <> ?
                ');
                $clearHome->execute([$nowUtc, $circleDbId, $placeId]);
            }

            $existingStmt = $db->prepare('SELECT id, circle_id FROM saved_places WHERE place_id = ? LIMIT 1');
            $existingStmt->execute([$placeId]);
            $existing = $existingStmt->fetch();

            if ($existing) {
                if ((int) $existing['circle_id'] !== $circleDbId) {
                    $db->rollBack();
                    Response::error('Place belongs to a different family circle.', 403, 'FORBIDDEN_PLACE');
                }
                $upd = $db->prepare('
                    UPDATE saved_places
                    SET name = ?, category = ?, latitude = ?, longitude = ?, radius_meters = ?,
                        is_home = ?, notify_on_enter = ?, notify_on_exit = ?,
                        deleted_at = NULL, updated_at = ?
                    WHERE id = ?
                ');
                $upd->execute([
                    $name,
                    $category,
                    $coordCheck['latitude'],
                    $coordCheck['longitude'],
                    $radiusMeters,
                    $isHome ? 1 : 0,
                    $notifyEnter,
                    $notifyExit,
                    $nowUtc,
                    (int) $existing['id'],
                ]);
            } else {
                $ins = $db->prepare('
                    INSERT INTO saved_places (
                        place_id, circle_id, name, category, latitude, longitude, radius_meters,
                        is_home, notify_on_enter, notify_on_exit, created_by_device_id,
                        deleted_at, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
                ');
                $ins->execute([
                    $placeId,
                    $circleDbId,
                    $name,
                    $category,
                    $coordCheck['latitude'],
                    $coordCheck['longitude'],
                    $radiusMeters,
                    $isHome ? 1 : 0,
                    $notifyEnter,
                    $notifyExit,
                    $actorDeviceDbId,
                    $nowUtc,
                    $nowUtc,
                ]);
            }

            $db->commit();
        } catch (ResponseTerminateException $re) {
            throw $re;
        } catch (Throwable $e) {
            if ($db->inTransaction()) {
                $db->rollBack();
            }
            Security::logError('performPlaceUpsert failed', $e);
            Response::error('Failed to save place.', 500, 'PLACE_SAVE_FAILED');
        }
    }

    private static function performPlaceDelete(PDO $db, int $circleDbId, string $placeId): void
    {
        $nowUtc = gmdate('Y-m-d H:i:s');
        $upd = $db->prepare('
            UPDATE saved_places
            SET deleted_at = ?, updated_at = ?
            WHERE circle_id = ? AND place_id = ? AND deleted_at IS NULL
        ');
        $upd->execute([$nowUtc, $nowUtc, $circleDbId, $placeId]);
    }

    private static function loadCirclePayload(
        PDO $db,
        int $circleDbId,
        ?int $selfDeviceDbId,
        ?string $eventsSince,
        int $now,
        int $onlineThreshold,
        int $staleThreshold
    ): array {
        $memStmt = $db->prepare('
            SELECT
                d.id AS device_db_id,
                d.device_id,
                d.device_name,
                cm.member_name,
                cm.role,
                cm.avatar_color,
                cm.joined_at,
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
            FROM circle_members cm
            JOIN devices d ON d.id = cm.device_id
            JOIN device_status ds ON ds.device_id = d.id
            WHERE cm.circle_id = ?
              AND cm.left_at IS NULL
              AND d.unregistered_at IS NULL
            ORDER BY cm.joined_at ASC
        ');
        $memStmt->execute([$circleDbId]);
        $members = [];
        foreach ($memStmt->fetchAll() as $row) {
            $formatted = DeviceService::formatDeviceForDashboard($row, $now, $onlineThreshold, $staleThreshold);
            $formatted['member_name'] = (string) $row['member_name'];
            $formatted['role'] = (string) $row['role'];
            $formatted['avatar_color'] = (string) $row['avatar_color'];
            $formatted['joined_at'] = DeviceService::toIsoUtc((string) $row['joined_at']);
            $formatted['is_self'] = $selfDeviceDbId !== null && ((int) $row['device_db_id'] === $selfDeviceDbId);
            $members[] = $formatted;
        }

        $circlePublicStmt = $db->prepare('SELECT circle_id FROM family_circles WHERE id = ? LIMIT 1');
        $circlePublicStmt->execute([$circleDbId]);
        $circlePublicId = (string) ($circlePublicStmt->fetchColumn() ?: '');

        $placesStmt = $db->prepare('
            SELECT place_id, name, category, latitude, longitude, radius_meters,
                   is_home, notify_on_enter, notify_on_exit, updated_at
            FROM saved_places
            WHERE circle_id = ? AND deleted_at IS NULL
            ORDER BY is_home DESC, created_at ASC
        ');
        $placesStmt->execute([$circleDbId]);
        $places = [];
        foreach ($placesStmt->fetchAll() as $p) {
            $places[] = [
                'place_id'        => (string) $p['place_id'],
                'circle_id'       => $circlePublicId,
                'name'            => (string) $p['name'],
                'category'        => (string) $p['category'],
                'latitude'        => (float) $p['latitude'],
                'longitude'       => (float) $p['longitude'],
                'radius_meters'   => (int) $p['radius_meters'],
                'is_home'         => (bool) $p['is_home'],
                'notify_on_enter' => (bool) $p['notify_on_enter'],
                'notify_on_exit'  => (bool) $p['notify_on_exit'],
                'updated_at'      => DeviceService::toIsoUtc((string) $p['updated_at']),
            ];
        }

        $sinceUtc = null;
        if ($eventsSince !== null && trim($eventsSince) !== '') {
            $ts = Security::validateTimestamp($eventsSince);
            if ($ts['valid']) {
                $sinceUtc = $ts['utc_datetime'];
            }
        }

        $sql = '
            SELECT pe.event_id, d.device_id, pe.member_name, pe.place_id, pe.place_name,
                   pe.place_category, pe.event_type, pe.occurred_at
            FROM place_events pe
            JOIN devices d ON d.id = pe.device_id
            WHERE pe.circle_id = ?
        ';
        $params = [$circleDbId];
        if ($sinceUtc !== null) {
            $sql .= ' AND pe.occurred_at > ?';
            $params[] = $sinceUtc;
        }
        $sql .= ' ORDER BY pe.occurred_at DESC, pe.id DESC LIMIT 40';

        $evtStmt = $db->prepare($sql);
        $evtStmt->execute($params);
        $events = [];
        foreach ($evtStmt->fetchAll() as $e) {
            $events[] = [
                'event_id'       => (string) $e['event_id'],
                'device_id'      => (string) $e['device_id'],
                'member_name'    => (string) $e['member_name'],
                'place_id'       => (string) $e['place_id'],
                'place_name'     => (string) $e['place_name'],
                'place_category' => (string) $e['place_category'],
                'event_type'     => (string) $e['event_type'],
                'occurred_at'    => DeviceService::toIsoUtc((string) $e['occurred_at']),
            ];
        }

        return [
            'members'     => $members,
            'places'      => $places,
            'events'      => $events,
            'thresholds'  => [
                'online_threshold_seconds' => $onlineThreshold,
                'location_stale_seconds'   => $staleThreshold,
            ],
            'server_time' => gmdate('Y-m-d\TH:i:s\Z', $now),
        ];
    }

    private static function generateUniqueInvite(PDO $db): array
    {
        for ($attempt = 0; $attempt < 6; $attempt++) {
            $candidate = Security::generateInviteCode();
            $chk = $db->prepare('SELECT id FROM family_circles WHERE invite_code_hash = ? LIMIT 1');
            $chk->execute([$candidate['hash']]);
            if (!$chk->fetch()) {
                return $candidate;
            }
        }
        throw new RuntimeException('Unable to generate unique family invite code.');
    }
}
