import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:locashare_mobile/models/device_state.dart';
import 'package:locashare_mobile/screens/home_screen.dart';
import 'package:locashare_mobile/services/locashare_api.dart';
import 'package:locashare_mobile/services/location_controller.dart';
import 'package:locashare_mobile/services/native_bridge.dart';
import 'package:locashare_mobile/widgets/qr_matrix.dart';

class FakeNativeBridge implements NativeLocationBridge {
  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();

  Map<String, dynamic> store = {
    'serverUrl': 'https://locashare.example.com',
    'deviceId': '',
    'deviceToken': '',
    'deviceName': 'Pixel Test',
    'defaultDeviceName': 'Pixel Test',
    'isSharing': false,
    'statusState': 'unregistered',
    'updateIntervalMs': 30000,
    'hasLocationPermission': false,
    'hasFineLocation': false,
    'hasNotificationPermission': true,
    'isLocationServiceEnabled': true,
    'isNetworkConnected': true,
    'networkType': 'wifi',
    'hasPendingFix': false,
  };

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
}
