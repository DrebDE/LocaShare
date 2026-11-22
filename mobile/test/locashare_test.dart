import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:locashare_mobile/models/device_state.dart';
import 'package:locashare_mobile/models/family_models.dart';
import 'package:locashare_mobile/screens/home_screen.dart';
import 'package:locashare_mobile/screens/main_shell.dart';
import 'package:locashare_mobile/services/geofence_math.dart';
import 'package:locashare_mobile/services/locashare_api.dart';
import 'package:locashare_mobile/services/location_controller.dart';
import 'package:locashare_mobile/services/native_bridge.dart';
import 'package:locashare_mobile/widgets/qr_matrix.dart';

class FakeNativeBridge implements NativeLocationBridge {
  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();

  Map<String, dynamic> store = {
    'backendMode': 'php',
    'serverUrl': 'https://locashare.example.com',
    'supabaseUrl': '',
    'supabaseAnonKey': '',
    'deviceId': '',
    'deviceToken': '',
    'deviceName': 'Pixel Test',
    'defaultDeviceName': 'Pixel Test',
    'isSharing': false,
    'statusState': 'unregistered',
    'smartHomeMode': true,
    'updateIntervalMs': 30000,
    'hasLocationPermission': false,
    'hasFineLocation': false,
    'hasNotificationPermission': true,
    'isLocationServiceEnabled': true,
    'isNetworkConnected': true,
    'networkType': 'wifi',
    'hasPendingFix': false,
  };

  String syncedPlacesJson = '[]';
  double? mockCurrentLat = 14.554729;
  double? mockCurrentLng = 121.024445;

  bool permissionGrantOnRequest = true;
  bool startSharingCalled = false;
  bool stopSharingCalled = false;

  void emitSnapshot(Map<String, dynamic> patch) {
    store = {...store, ...patch};
    _controller.add(Map<String, dynamic>.from(store));
  }

  @override
  Future<Map<String, dynamic>> getState() async =>
      Map<String, dynamic>.from(store);

  @override
  Future<Map<String, dynamic>> checkPermissions() async => {
        'hasLocationPermission': store['hasLocationPermission'],
        'hasFineLocation': store['hasFineLocation'],
        'hasNotificationPermission': store['hasNotificationPermission'],
        'isLocationServiceEnabled': store['isLocationServiceEnabled'],
      };

  @override
  Future<Map<String, dynamic>> requestLocationPermissions() async {
    store['hasLocationPermission'] = permissionGrantOnRequest;
    store['hasFineLocation'] = permissionGrantOnRequest;
    return checkPermissions();
  }

  @override
  Future<void> openAppSettings() async {}

  @override
  Future<void> openLocationSettings() async {}

  @override
  Future<Map<String, dynamic>> setServerUrl(String serverUrl) async {
    store['serverUrl'] = serverUrl;
    return getState();
  }

  @override
  Future<Map<String, dynamic>> setBackendConfig({
    required String backendMode,
    required String serverUrl,
    required String supabaseUrl,
    required String supabaseAnonKey,
  }) async {
    store['backendMode'] = backendMode;
    store['serverUrl'] = serverUrl;
    store['supabaseUrl'] = supabaseUrl;
    store['supabaseAnonKey'] = supabaseAnonKey;
    return getState();
  }

  @override
  Future<Map<String, dynamic>> setSmartHomeMode(bool enabled) async {
    store['smartHomeMode'] = enabled;
    return getState();
  }

  @override
  Future<Map<String, dynamic>> setCircleInfo({
    required String circleId,
    required String circleName,
    required String memberName,
  }) async {
    store['circleId'] = circleId;
    store['circleName'] = circleName;
    store['memberName'] = memberName;
    return getState();
  }

  @override
  Future<Map<String, dynamic>> setSavedPlacesJson(String placesJson) async {
    syncedPlacesJson = placesJson;
    return getState();
  }

  @override
  Future<Map<String, dynamic>> syncFamilyAlertsNow() async => getState();

  @override
  Future<Map<String, dynamic>> getCurrentLocation() async {
    if (mockCurrentLat != null && mockCurrentLng != null) {
      return {'latitude': mockCurrentLat, 'longitude': mockCurrentLng};
    }
    return const {};
  }

  @override
  Future<Map<String, dynamic>> setIntervalMs(int intervalMs) async {
    store['updateIntervalMs'] = intervalMs;
    return getState();
  }

  @override
  Future<Map<String, dynamic>> configureDevice({
    required String serverUrl,
    required String deviceId,
    required String deviceToken,
    required String deviceName,
    required String statusState,
    required int updateIntervalMs,
  }) async {
    store['serverUrl'] = serverUrl;
    store['deviceId'] = deviceId;
    store['deviceToken'] = deviceToken;
    store['deviceName'] = deviceName;
    store['statusState'] = statusState;
    store['updateIntervalMs'] = updateIntervalMs;
    return getState();
  }

  @override
  Future<Map<String, dynamic>> startSharing() async {
    startSharingCalled = true;
    store['isSharing'] = true;
    store['statusState'] = 'sharing';
    return getState();
  }

  @override
  Future<Map<String, dynamic>> stopSharing() async {
    stopSharingCalled = true;
    store['isSharing'] = false;
    store['statusState'] =
        (store['deviceId'] as String).isNotEmpty ? 'paused' : 'unregistered';
    return getState();
  }

  @override
  Future<Map<String, dynamic>> flushPendingNow() async => getState();

  @override
  Future<Map<String, dynamic>> clearLocationMetadata() async {
    store['hasPendingFix'] = false;
    store.remove('lastUploadAt');
    store.remove('lastFixAt');
    store.remove('lastAccuracy');
    return getState();
  }

  @override
  Future<Map<String, dynamic>> unregisterReset() async {
    store['deviceId'] = '';
    store['deviceToken'] = '';
    store['isSharing'] = false;
    store['statusState'] = 'unregistered';
    store['hasPendingFix'] = false;
    return getState();
  }

  @override
  Stream<Map<String, dynamic>> get stateStream => _controller.stream;

  void dispose() {
    _controller.close();
  }
}

MockClient _buildMockApiClient({
  String code = 'ABCD-2345',
  int pairedCount = 0,
}) {
  return MockClient((request) async {
    final path = request.url.path;
    if (path.endsWith('/api/health.php')) {
      return http.Response(jsonEncode({'success': true, 'status': 'ok'}), 200);
    }
    if (path.endsWith('/api/device/register.php')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'success': true,
          'device_id': 'dev_test1234567890',
          'device_name': body['device_name'] ?? 'Pixel Test',
          'device_token': 'tok_secret_unit_test_123',
          'pairing_code': code,
          'pairing_qr_payload': 'locashare://pair?code=$code',
          'pairing_expires_at':
              DateTime.now().toUtc().add(const Duration(minutes: 5)).toIso8601String(),
          'status_state': 'waiting_for_pairing',
          'sharing_enabled': false,
        }),
        201,
      );
    }
    if (path.endsWith('/api/device/pairing-code.php')) {
      return http.Response(
        jsonEncode({
          'success': true,
          'pairing_code': 'WXYZ-6789',
          'pairing_qr_payload': 'locashare://pair?code=WXYZ-6789',
          'pairing_expires_at':
              DateTime.now().toUtc().add(const Duration(minutes: 5)).toIso8601String(),
          'paired_dashboards': pairedCount,
        }),
        200,
      );
    }
    if (path.endsWith('/api/device/status.php')) {
      return http.Response(
        jsonEncode({
          'success': true,
          'status': {
            'device_id': 'dev_test1234567890',
            'device_name': 'Pixel Test',
            'sharing_enabled': false,
            'status_state':
                pairedCount > 0 ? 'registered' : 'waiting_for_pairing',
            'paired_dashboards_count': pairedCount,
            'has_stored_location': false,
          },
        }),
        200,
      );
    }
    if (path.endsWith('/api/device/unpair.php')) {
      return http.Response(
        jsonEncode({
          'success': true,
          'revoked_pairings': 1,
          'location_cleared': true,
        }),
        200,
      );
    }
    if (path.endsWith('/api/location/delete.php')) {
      return http.Response(
        jsonEncode({'success': true, 'location_deleted': true}),
        200,
      );
    }
    if (path.endsWith('/api/device/unregister.php')) {
      return http.Response(
        jsonEncode({'success': true, 'unregistered': true}),
        200,
      );
    }
    if (path.endsWith('/api/family/circle/create.php') ||
        path.endsWith('/rest/v1/rpc/rpc_create_family_circle')) {
      return http.Response(
        jsonEncode({
          'success': true,
          'circle': {
            'circle_id': 'cir_testfamily01',
            'name': 'Santos Family',
            'invite_code': 'FAM-7H3K-9P2M',
            'my_role': 'admin',
            'my_member_name': 'Mom',
          },
          'members': [
            {
              'device_id': 'dev_test1234567890',
              'device_name': 'Pixel Test',
              'member_name': 'Mom',
              'role': 'admin',
              'avatar_color': '#0EA5E9',
              'is_self': true,
              'sharing_enabled': true,
              'status_state': 'sharing',
              'presence_mode': 'at_home',
              'current_place_name': 'Our House',
              'home_privacy_masked': true,
              'is_online': true,
              'battery': 92,
              'has_location': true,
              'is_location_fresh': true,
              'location': {
                'latitude': 14.554729,
                'longitude': 121.024445,
                'accuracy': 12.0,
                'recorded_at': DateTime.now().toUtc().toIso8601String(),
                'is_fresh': true,
              },
            },
            {
              'device_id': 'dev_alex002',
              'device_name': 'Alex Phone',
              'member_name': 'Alex',
              'role': 'member',
              'avatar_color': '#10B981',
              'is_self': false,
              'sharing_enabled': true,
              'status_state': 'sharing',
              'presence_mode': 'away',
              'home_privacy_masked': false,
              'is_online': true,
              'battery': 78,
              'has_location': true,
              'is_location_fresh': true,
              'location': {
                'latitude': 14.562000,
                'longitude': 121.031000,
                'accuracy': 9.0,
                'recorded_at': DateTime.now().toUtc().toIso8601String(),
                'is_fresh': true,
              },
            },
          ],
          'places': const [],
          'events': const [],
        }),
        201,
      );
    }
    if (path.endsWith('/api/family/places/upsert.php') ||
        path.endsWith('/rest/v1/rpc/rpc_upsert_saved_place')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final name = (body['name'] ?? body['p_name'] ?? 'Home') as String;
      final cat = (body['category'] ?? body['p_category'] ?? 'home') as String;
      final lat = ((body['latitude'] ?? body['p_latitude'] ?? 14.554729) as num).toDouble();
      final lng = ((body['longitude'] ?? body['p_longitude'] ?? 121.024445) as num).toDouble();
      final radius = ((body['radius_meters'] ?? body['p_radius_meters'] ?? 150) as num).toInt();
      return http.Response(
        jsonEncode({
          'success': true,
          'circle': {
            'circle_id': 'cir_testfamily01',
            'name': 'Santos Family',
            'invite_code': 'FAM-7H3K-9P2M',
            'my_role': 'admin',
            'my_member_name': 'Mom',
          },
          'members': const [],
          'places': [
            {
              'place_id': 'plc_home001',
              'circle_id': 'cir_testfamily01',
              'name': name,
              'category': cat,
              'latitude': lat,
              'longitude': lng,
              'radius_meters': radius,
              'is_home': cat == 'home',
              'notify_on_enter': true,
              'notify_on_exit': true,
            }
          ],
          'events': [
            {
              'event_id': 'evt_001',
              'device_id': 'dev_alex002',
              'member_name': 'Alex',
              'place_id': 'plc_home001',
              'place_name': name,
              'place_category': cat,
              'event_type': 'exited',
              'occurred_at': DateTime.now().toUtc().toIso8601String(),
            }
          ],
        }),
        200,
      );
    }
    if (path.endsWith('/api/family/circle/snapshot.php') ||
        path.endsWith('/rest/v1/rpc/rpc_get_circle_snapshot')) {
      return http.Response(
        jsonEncode({
          'success': true,
          'circle': null,
          'members': const [],
          'places': const [],
          'events': const [],
        }),
        200,
      );
    }
    if (path.endsWith('/rest/v1/rpc/rpc_register_device')) {
      return http.Response(
        jsonEncode({
          'success': true,
          'device_id': 'dev_supa001',
          'device_name': 'Pixel Test',
          'device_token': 'tok_supa_secret_123456',
          'status_state': 'registered',
          'sharing_enabled': false,
        }),
        200,
      );
    }
    if (path.endsWith('/rest/v1/')) {
      return http.Response('{}', 200);
    }
    return http.Response(jsonEncode({'success': false, 'error': 'Not found'}), 404);
  });
}

void main() {
  group('QrMatrixEncoder', () {
    test('encodes pairing URI into Version 3 29x29 QR with valid finders', () {
      final matrix = QrMatrixEncoder.encode('locashare://pair?code=ABCD-2345');
      expect(matrix.length, 29);
      expect(matrix.first.length, 29);

      // Top-left 7x7 finder outer border is dark
      for (var i = 0; i < 7; i++) {
        expect(matrix[0][i], isTrue);
        expect(matrix[6][i], isTrue);
        expect(matrix[i][0], isTrue);
        expect(matrix[i][6], isTrue);
      }
      // Top-left 3x3 finder core is dark
      expect(matrix[3][3], isTrue);
      // Fixed dark module at (size - 8, 8)
      expect(matrix[29 - 8][8], isTrue);
    });
  });

  group('LocationController consent & lifecycle flows', () {
    late FakeNativeBridge bridge;
    late LocationController controller;

    setUp(() {
      bridge = FakeNativeBridge();
      controller = LocationController(
        api: LocaShareApi(client: _buildMockApiClient()),
        bridge: bridge,
        enableBackgroundTimers: false,
      );
    });

    tearDown(() {
      controller.dispose();
      bridge.dispose();
    });

    test('registration enters waiting_for_pairing and never auto-starts sharing',
        () async {
      await controller.initialize();
      expect(controller.state.statusState, PhoneStatusState.unregistered);

      final ok = await controller.registerDevice(customDeviceName: 'Pixel Test');
      expect(ok, isTrue);
      expect(controller.state.isRegistered, isTrue);
      expect(controller.state.statusState, PhoneStatusState.waitingForPairing);
      expect(controller.state.pairingCode, 'ABCD-2345');
      expect(controller.state.isSharing, isFalse);
      expect(bridge.startSharingCalled, isFalse);
    });

    test('startSharing refuses cleanly when location permission is missing',
        () async {
      await controller.initialize();
      await controller.registerDevice();

      final started = await controller.startSharing();
      expect(started, isFalse);
      expect(controller.state.isSharing, isFalse);
      expect(controller.state.statusState, PhoneStatusState.permissionMissing);
      expect(bridge.startSharingCalled, isFalse);
    });

    test('granting permission and tapping Start sharing starts foreground service',
        () async {
      await controller.initialize();
      await controller.registerDevice();

      final granted = await controller.requestPermissionsFromOs();
      expect(granted, isTrue);

      final started = await controller.startSharing();
      expect(started, isTrue);
      expect(controller.state.isSharing, isTrue);
      expect(controller.state.statusState, PhoneStatusState.sharing);
      expect(bridge.startSharingCalled, isTrue);

      // Reflect native offline & pending-fix replacement updates
      bridge.emitSnapshot({
        'isSharing': true,
        'statusState': 'offline',
        'isNetworkConnected': false,
        'networkType': 'none',
        'hasPendingFix': true,
        'pendingRecordedAt': '2026-11-13T10:00:00Z',
        'lastAccuracy': 14.2,
      });
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.statusState, PhoneStatusState.offline);
      expect(controller.state.hasPendingFix, isTrue);
      expect(controller.state.lastAccuracyMeters, 14.2);

      await controller.stopSharing();
      expect(controller.state.isSharing, isFalse);
      expect(controller.state.statusState, PhoneStatusState.paused);
      expect(bridge.stopSharingCalled, isTrue);
    });

    test('revoke pairings, delete location, and unregister clear state',
        () async {
      await controller.initialize();
      await controller.registerDevice();

      final revoked = await controller.revokeDashboardPairings();
      expect(revoked, isTrue);
      expect(controller.state.pairedDashboardsCount, 0);

      final deleted = await controller.deleteStoredLocation();
      expect(deleted, isTrue);
      expect(controller.state.hasPendingFix, isFalse);

      final unreg = await controller.unregisterDevice();
      expect(unreg, isTrue);
      expect(controller.state.isRegistered, isFalse);
      expect(controller.state.statusState, PhoneStatusState.unregistered);
    });
  });

  group('HomeScreen widget UI flows', () {
    testWidgets(
        'renders Register without login, shows pairing code & rationale prompt',
        (tester) async {
      final bridge = FakeNativeBridge();
      final controller = LocationController(
        api: LocaShareApi(client: _buildMockApiClient()),
        bridge: bridge,
        enableBackgroundTimers: false,
      );
      await controller.initialize();

      await tester.pumpWidget(
        MaterialApp(home: HomeScreen(controller: controller)),
      );

      // Unregistered state shows Register button and no password/email fields
      expect(find.text('Register this device'), findsOneWidget);
      expect(find.textContaining('Password'), findsNothing);

      // Tap Register this device
      await tester.ensureVisible(find.text('Register this device'));
      await tester.tap(find.text('Register this device'));
      await tester.pumpAndSettle();

      // Pairing code, QR card, and controls appear
      expect(find.text('ABCD-2345'), findsOneWidget);
      expect(find.text('Start sharing'), findsOneWidget);
      expect(find.text('Stop sharing'), findsOneWidget);
      expect(find.text('Revoke Dashboard Pairings'), findsOneWidget);
      expect(find.text('Delete Stored Location'), findsOneWidget);
      expect(find.text('Unregister this device'), findsOneWidget);

      // Tap Start sharing without location permission -> shows explicit explanation dialog
      await tester.ensureVisible(find.text('Start sharing'));
      await tester.tap(find.text('Start sharing'));
      await tester.pumpAndSettle();
      expect(find.text('Location Permission Needed'), findsOneWidget);

      // Confirm rationale -> grants permission -> starts sharing
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(controller.state.isSharing, isTrue);
      expect(find.text('Sharing Live'), findsOneWidget);

      controller.dispose();
      bridge.dispose();
    });

    testWidgets('warns clearly when remote server uses plain HTTP instead of HTTPS',
        (tester) async {
      final bridge = FakeNativeBridge();
      bridge.store['serverUrl'] = 'http://tracker.example.org';
      final controller = LocationController(
        api: LocaShareApi(client: _buildMockApiClient()),
        bridge: bridge,
        enableBackgroundTimers: false,
      );
      await controller.initialize();

      await tester.pumpWidget(
        MaterialApp(home: HomeScreen(controller: controller)),
      );
      expect(
        find.textContaining('Away-from-home mobile tracking requires a public HTTPS backend'),
        findsOneWidget,
      );

      controller.dispose();
      bridge.dispose();
    });
  });

  group('GeofenceMath & Family Life360 flows', () {
    test('Haversine distance and Web Mercator projection roundtrip stay accurate', () {
      final dZero = GeofenceMath.haversineMeters(14.554729, 121.024445, 14.554729, 121.024445);
      expect(dZero, lessThan(0.01));

      final dAway = GeofenceMath.haversineMeters(14.554729, 121.024445, 14.556729, 121.024445);
      expect(dAway, inInclusiveRange(215.0, 230.0));

      final px = GeofenceMath.latLngToWorldPx(14.554729, 121.024445, 15.0);
      final back = GeofenceMath.worldPxToLatLng(px.dx, px.dy, 15.0);
      expect((back.lat - 14.554729).abs(), lessThan(1e-5));
      expect((back.lng - 121.024445).abs(), lessThan(1e-5));
    });

    test('Supabase Cloud config, Family Circle creation & Saved Place sync to native bridge', () async {
      final bridge = FakeNativeBridge();
      final controller = LocationController(
        api: LocaShareApi(client: _buildMockApiClient()),
        bridge: bridge,
        enableBackgroundTimers: false,
      );
      await controller.initialize();

      final switched = await controller.saveBackendConfig(
        mode: BackendMode.supabase,
        supabaseUrl: 'https://demo.supabase.co',
        supabaseAnonKey: 'anon_public_key_example_123456',
      );
      expect(switched, isTrue);
      expect(controller.state.isSupabaseMode, isTrue);
      expect(bridge.store['backendMode'], 'supabase');

      final regOk = await controller.registerDevice(customDeviceName: 'Pixel Test');
      expect(regOk, isTrue);
      expect(controller.state.deviceId, 'dev_supa001');

      final created = await controller.createFamilyCircle(
        circleName: 'Santos Family',
        memberName: 'Mom',
      );
      expect(created, isTrue);
      expect(controller.family.circle?.inviteCode, 'FAM-7H3K-9P2M');
      expect(controller.family.members.length, 2);
      expect(bridge.store['circleId'], 'cir_testfamily01');

      final savedHome = await controller.upsertSavedPlace(
        name: 'Our House',
        category: PlaceCategory.home,
        latitude: 14.554729,
        longitude: 121.024445,
        radiusMeters: 150,
        notifyOnEnter: true,
        notifyOnExit: true,
      );
      expect(savedHome, isTrue);
      expect(controller.family.places.length, 1);
      expect(controller.family.events.first.summaryText, 'Alex left Our House');

      final decodedSynced = jsonDecode(bridge.syncedPlacesJson) as List<dynamic>;
      expect(decodedSynced.length, 1);
      expect((decodedSynced.first as Map<String, dynamic>)['is_home'], isTrue);

      controller.dispose();
      bridge.dispose();
    });

    testWidgets('MainShell renders Family Map & Places & Alerts with At Home vs Away status', (tester) async {
      final bridge = FakeNativeBridge();
      final controller = LocationController(
        api: LocaShareApi(client: _buildMockApiClient()),
        bridge: bridge,
        enableBackgroundTimers: false,
      );
      await controller.initialize();
      await controller.registerDevice();
      await controller.createFamilyCircle(circleName: 'Santos Family', memberName: 'Mom');

      await tester.pumpWidget(
        MaterialApp(
          home: MainShell(
            controller: controller,
            enableNetworkTiles: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Family Map tab shows circle name, At Home vs Out of House pills
      expect(find.text('Santos Family'), findsOneWidget);
      expect(find.text('At Home · Battery Saver'), findsOneWidget);
      expect(find.text('Out of House · Live'), findsOneWidget);

      // Switch to Places & Alerts tab
      await tester.tap(find.text('Places & Alerts'));
      await tester.pumpAndSettle();
      expect(find.text('Set Our House (Home Geofence)'), findsOneWidget);
      expect(find.text('Set Home Location'), findsOneWidget);

      controller.dispose();
      bridge.dispose();
    });
  });
}
