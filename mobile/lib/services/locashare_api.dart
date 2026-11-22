import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/device_state.dart';
import '../models/family_models.dart';

class ApiResponse<T> {
  const ApiResponse({
    required this.ok,
    required this.statusCode,
    this.data,
    this.error,
    this.errorCode,
    this.isNetworkError = false,
  });

  final bool ok;
  final int statusCode;
  final T? data;
  final String? error;
  final String? errorCode;
  final bool isNetworkError;
}

class RegistrationResult {
  const RegistrationResult({
    required this.deviceId,
    required this.deviceName,
    required this.deviceToken,
    required this.pairingCode,
    required this.pairingQrPayload,
    required this.pairingExpiresAt,
    required this.statusState,
  });

  final String deviceId;
  final String deviceName;
  final String deviceToken;
  final String pairingCode;
  final String pairingQrPayload;
  final DateTime? pairingExpiresAt;
  final String statusState;
}

class PairingCodeResult {
  const PairingCodeResult({
    required this.pairingCode,
    required this.pairingQrPayload,
    required this.pairingExpiresAt,
    required this.pairedDashboardsCount,
  });

  final String pairingCode;
  final String pairingQrPayload;
  final DateTime? pairingExpiresAt;
  final int pairedDashboardsCount;
}

class DeviceServerStatus {
  const DeviceServerStatus({
    required this.deviceId,
    required this.deviceName,
    required this.sharingEnabled,
    required this.statusState,
    required this.pairedDashboardsCount,
    required this.hasStoredLocation,
    this.lastAccuracy,
    this.locationRecordedAt,
    this.lastHeartbeatAt,
    this.pairingCodeExpiresAt,
  });

  final String deviceId;
  final String deviceName;
  final bool sharingEnabled;
  final String statusState;
  final int pairedDashboardsCount;
  final bool hasStoredLocation;
  final double? lastAccuracy;
  final DateTime? locationRecordedAt;
  final DateTime? lastHeartbeatAt;
  final DateTime? pairingCodeExpiresAt;
}

/// REST API client for LocaShare PHP backend endpoints.
class LocaShareApi {
  LocaShareApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const Duration _timeout = Duration(seconds: 12);

  Uri _endpoint(String serverUrl, String path, [Map<String, String>? query]) {
    final normalizedBase = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$normalizedBase$path');
    if (query != null && query.isNotEmpty) {
      return uri.replace(queryParameters: query);
    }
    return uri;
  }

  Future<ApiResponse<void>> checkHealth(String serverUrl) async {
    return _execute<void>(
      () => _client.get(
        _endpoint(serverUrl, '/api/health.php'),
        headers: const {'Accept': 'application/json'},
      ),
      (_) {},
    );
  }

  Future<ApiResponse<RegistrationResult>> registerDevice({
    required String serverUrl,
    required String deviceName,
  }) async {
    return _execute<RegistrationResult>(
      () => _client.post(
        _endpoint(serverUrl, '/api/device/register.php'),
        headers: const {
          'Accept': 'application/json',
          'Content-Type': 'application/json; charset=utf-8',
        },
        body: jsonEncode({'device_name': deviceName}),
      ),
      (json) => RegistrationResult(
        deviceId: (json['device_id'] as String?) ?? '',
        deviceName: (json['device_name'] as String?) ?? deviceName,
        deviceToken: (json['device_token'] as String?) ?? '',
        pairingCode: (json['pairing_code'] as String?) ?? '',
        pairingQrPayload: (json['pairing_qr_payload'] as String?) ?? '',
        pairingExpiresAt: _parseIso(json['pairing_expires_at']),
        statusState: (json['status_state'] as String?) ?? 'waiting_for_pairing',
      ),
    );
  }

  Future<ApiResponse<PairingCodeResult>> generatePairingCode({
    required String serverUrl,
    required String deviceId,
    required String deviceToken,
  }) async {
    return _execute<PairingCodeResult>(
      () => _client.post(
        _endpoint(serverUrl, '/api/device/pairing-code.php'),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json; charset=utf-8',
          'Authorization': 'Bearer $deviceToken',
        },
        body: jsonEncode({'device_id': deviceId}),
      ),
      (json) => PairingCodeResult(
        pairingCode: (json['pairing_code'] as String?) ?? '',
        pairingQrPayload: (json['pairing_qr_payload'] as String?) ?? '',
        pairingExpiresAt: _parseIso(json['pairing_expires_at']),
        pairedDashboardsCount: (json['paired_dashboards'] as num?)?.toInt() ?? 0,
      ),
    );
  }

  Future<ApiResponse<DeviceServerStatus>> fetchStatus({
    required String serverUrl,
    required String deviceId,
    required String deviceToken,
  }) async {
    return _execute<DeviceServerStatus>(
      () => _client.get(
        _endpoint(serverUrl, '/api/device/status.php', {'device_id': deviceId}),
        headers: {
          'Accept': 'application/json',
          'Authorization': 'Bearer $deviceToken',
          'X-Device-Id': deviceId,
        },
      ),
      (json) {
        final s = (json['status'] as Map<String, dynamic>?) ?? const {};
        return DeviceServerStatus(
          deviceId: (s['device_id'] as String?) ?? deviceId,
          deviceName: (s['device_name'] as String?) ?? 'Android Phone',
          sharingEnabled: s['sharing_enabled'] == true,
          statusState: (s['status_state'] as String?) ?? 'registered',
          pairedDashboardsCount:
              (s['paired_dashboards_count'] as num?)?.toInt() ?? 0,
          hasStoredLocation: s['has_stored_location'] == true,
          lastAccuracy: (s['last_accuracy'] as num?)?.toDouble(),
          locationRecordedAt: _parseIso(s['location_recorded_at']),
          lastHeartbeatAt: _parseIso(s['last_heartbeat_at']),
          pairingCodeExpiresAt: _parseIso(s['pairing_code_expires_at']),
        );
      },
    );
  }

  Future<ApiResponse<void>> sendHeartbeat({
    required String serverUrl,
    required String deviceId,
    required String deviceToken,
    required bool sharingEnabled,
    required String statusState,
    String? networkType,
  }) async {
    return _execute<void>(
      () => _client.post(
        _endpoint(serverUrl, '/api/device/heartbeat.php'),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json; charset=utf-8',
          'Authorization': 'Bearer $deviceToken',
        },
        body: jsonEncode({
          'device_id': deviceId,
          'sharing_enabled': sharingEnabled,
          'status_state': statusState,
          'network_type': ?networkType,
        }),
      ),
      (_) {},
    );
  }

  Future<ApiResponse<int>> revokeAllPairings({
    required String serverUrl,
    required String deviceId,
    required String deviceToken,
    bool clearLocation = true,
  }) async {
    return _execute<int>(
      () => _client.post(
        _endpoint(serverUrl, '/api/device/unpair.php'),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json; charset=utf-8',
          'Authorization': 'Bearer $deviceToken',
        },
        body: jsonEncode({
          'device_id': deviceId,
          'clear_location': clearLocation,
        }),
      ),
      (json) => (json['revoked_pairings'] as num?)?.toInt() ?? 0,
    );
  }

  Future<ApiResponse<void>> deleteStoredLocation({
    required String serverUrl,
    required String deviceId,
    required String deviceToken,
  }) async {
    return _execute<void>(
      () => _client.post(
        _endpoint(serverUrl, '/api/location/delete.php'),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json; charset=utf-8',
          'Authorization': 'Bearer $deviceToken',
        },
        body: jsonEncode({'device_id': deviceId}),
      ),
      (_) {},
    );
  }

  Future<ApiResponse<void>> unregisterDevice({
    required String serverUrl,
    required String deviceId,
    required String deviceToken,
  }) async {
    return _execute<void>(
      () => _client.post(
        _endpoint(serverUrl, '/api/device/unregister.php'),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json; charset=utf-8',
          'Authorization': 'Bearer $deviceToken',
        },
        body: jsonEncode({'device_id': deviceId}),
      ),
      (_) {},
    );
  }

  // ──────────────────────────────────────────────────────────────
  // Unified Family Circle, Saved Places & Supabase Cloud Methods
  // ──────────────────────────────────────────────────────────────

  Map<String, String> _supabaseHeaders(String anonKey) => {
        'Accept': 'application/json',
        'Content-Type': 'application/json; charset=utf-8',
        'apikey': anonKey,
        'Authorization': 'Bearer $anonKey',
      };

  Uri _supabaseRpc(String supabaseUrl, String rpcName) {
    final base = supabaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base/rest/v1/rpc/$rpcName');
  }

  Future<ApiResponse<void>> checkBackendHealth(DeviceTrackerState s) async {
    if (s.isSupabaseMode) {
      if (!s.hasValidSupabaseConfig) {
        return const ApiResponse(
          ok: false,
          statusCode: 0,
          error: 'Enter a valid https:// Supabase Project URL and anon key.',
        );
      }
      return _execute<void>(
        () => _client.get(
          Uri.parse('${s.supabaseUrl.trim().replaceAll(RegExp(r'/+$'), '')}/rest/v1/'),
          headers: _supabaseHeaders(s.supabaseAnonKey),
        ),
        (_) {},
      );
    }
    return checkHealth(s.serverUrl);
  }

  Future<ApiResponse<RegistrationResult>> registerDeviceForBackend({
    required DeviceTrackerState state,
    required String deviceName,
  }) async {
    if (state.isSupabaseMode) {
      return _execute<RegistrationResult>(
        () => _client.post(
          _supabaseRpc(state.supabaseUrl, 'rpc_register_device'),
          headers: _supabaseHeaders(state.supabaseAnonKey),
          body: jsonEncode({'p_device_name': deviceName}),
        ),
        (json) => RegistrationResult(
          deviceId: (json['device_id'] as String?) ?? '',
          deviceName: (json['device_name'] as String?) ?? deviceName,
          deviceToken: (json['device_token'] as String?) ?? '',
          pairingCode: '',
          pairingQrPayload: '',
          pairingExpiresAt: null,
          statusState: (json['status_state'] as String?) ?? 'registered',
        ),
      );
    }
    return registerDevice(serverUrl: state.serverUrl, deviceName: deviceName);
  }

  Future<ApiResponse<FamilySnapshot>> createFamilyCircle({
    required DeviceTrackerState state,
    required String circleName,
    required String memberName,
  }) async {
    if (state.isSupabaseMode) {
      return _execute<FamilySnapshot>(
        () => _client.post(
          _supabaseRpc(state.supabaseUrl, 'rpc_create_family_circle'),
          headers: _supabaseHeaders(state.supabaseAnonKey),
          body: jsonEncode({
            'p_device_id': state.deviceId,
            'p_device_token': state.deviceToken,
            'p_circle_name': circleName,
            'p_member_name': memberName,
          }),
        ),
        FamilySnapshot.fromJson,
      );
    }
    return _execute<FamilySnapshot>(
      () => _client.post(
        _endpoint(state.serverUrl, '/api/family/circle/create.php'),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json; charset=utf-8',
          'Authorization': 'Bearer ${state.deviceToken}',
        },
        body: jsonEncode({
          'device_id': state.deviceId,
          'name': circleName,
          'member_name': memberName,
        }),
      ),
      FamilySnapshot.fromJson,
    );
  }

  Future<ApiResponse<FamilySnapshot>> joinFamilyCircle({
    required DeviceTrackerState state,
    required String inviteCode,
    required String memberName,
  }) async {
    if (state.isSupabaseMode) {
      return _execute<FamilySnapshot>(
        () => _client.post(
          _supabaseRpc(state.supabaseUrl, 'rpc_join_family_circle'),
          headers: _supabaseHeaders(state.supabaseAnonKey),
          body: jsonEncode({
            'p_device_id': state.deviceId,
            'p_device_token': state.deviceToken,
            'p_invite_code': inviteCode,
            'p_member_name': memberName,
          }),
        ),
        FamilySnapshot.fromJson,
      );
    }
    return _execute<FamilySnapshot>(
      () => _client.post(
        _endpoint(state.serverUrl, '/api/family/circle/join.php'),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json; charset=utf-8',
          'Authorization': 'Bearer ${state.deviceToken}',
        },
        body: jsonEncode({
          'device_id': state.deviceId,
          'invite_code': inviteCode,
          'member_name': memberName,
        }),
      ),
      FamilySnapshot.fromJson,
    );
  }

  Future<ApiResponse<void>> leaveFamilyCircle(DeviceTrackerState state) async {
    if (state.isSupabaseMode) {
      return _execute<void>(
        () => _client.post(
          _supabaseRpc(state.supabaseUrl, 'rpc_leave_family_circle'),
          headers: _supabaseHeaders(state.supabaseAnonKey),
          body: jsonEncode({
            'p_device_id': state.deviceId,
            'p_device_token': state.deviceToken,
          }),
        ),
        (_) {},
      );
    }
    return _execute<void>(
      () => _client.post(
        _endpoint(state.serverUrl, '/api/family/circle/leave.php'),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json; charset=utf-8',
          'Authorization': 'Bearer ${state.deviceToken}',
        },
        body: jsonEncode({'device_id': state.deviceId}),
      ),
      (_) {},
    );
  }

  Future<ApiResponse<String>> regenerateCircleInvite(DeviceTrackerState state) async {
    if (state.isSupabaseMode) {
      return _execute<String>(
        () => _client.post(
          _supabaseRpc(state.supabaseUrl, 'rpc_regenerate_circle_invite'),
          headers: _supabaseHeaders(state.supabaseAnonKey),
          body: jsonEncode({
            'p_device_id': state.deviceId,
            'p_device_token': state.deviceToken,
          }),
        ),
        (json) => (json['invite_code'] as String?) ?? '',
      );
    }
    return _execute<String>(
      () => _client.post(
        _endpoint(state.serverUrl, '/api/family/circle/regenerate-code.php'),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json; charset=utf-8',
          'Authorization': 'Bearer ${state.deviceToken}',
        },
        body: jsonEncode({'device_id': state.deviceId}),
      ),
      (json) => (json['invite_code'] as String?) ?? '',
    );
  }

  Future<ApiResponse<FamilySnapshot>> fetchCircleSnapshot(
    DeviceTrackerState state, {
    String? eventsSinceIso,
  }) async {
    if (state.isSupabaseMode) {
      return _execute<FamilySnapshot>(
        () => _client.post(
          _supabaseRpc(state.supabaseUrl, 'rpc_get_circle_snapshot'),
          headers: _supabaseHeaders(state.supabaseAnonKey),
          body: jsonEncode({
            'p_device_id': state.deviceId,
            'p_device_token': state.deviceToken,
            'p_events_since': eventsSinceIso,
          }),
        ),
        FamilySnapshot.fromJson,
      );
    }
    final query = <String, String>{'device_id': state.deviceId};
    if (eventsSinceIso != null && eventsSinceIso.isNotEmpty) {
      query['events_since'] = eventsSinceIso;
    }
    return _execute<FamilySnapshot>(
      () => _client.get(
        _endpoint(state.serverUrl, '/api/family/circle/snapshot.php', query),
        headers: {
          'Accept': 'application/json',
          'Authorization': 'Bearer ${state.deviceToken}',
          'X-Device-Id': state.deviceId,
        },
      ),
      FamilySnapshot.fromJson,
    );
  }

  Future<ApiResponse<FamilySnapshot>> upsertSavedPlace({
    required DeviceTrackerState state,
    String? placeId,
    required String name,
    required PlaceCategory category,
    required double latitude,
    required double longitude,
    required int radiusMeters,
    required bool isHome,
    required bool notifyOnEnter,
    required bool notifyOnExit,
  }) async {
    if (state.isSupabaseMode) {
      return _execute<FamilySnapshot>(
        () => _client.post(
          _supabaseRpc(state.supabaseUrl, 'rpc_upsert_saved_place'),
          headers: _supabaseHeaders(state.supabaseAnonKey),
          body: jsonEncode({
            'p_device_id': state.deviceId,
            'p_device_token': state.deviceToken,
            'p_place_id': (placeId != null && placeId.isNotEmpty) ? placeId : null,
            'p_name': name,
            'p_category': category.toWire(),
            'p_latitude': latitude,
            'p_longitude': longitude,
            'p_radius_meters': radiusMeters,
            'p_is_home': isHome,
            'p_notify_on_enter': notifyOnEnter,
            'p_notify_on_exit': notifyOnExit,
          }),
        ),
        FamilySnapshot.fromJson,
      );
    }
    return _execute<FamilySnapshot>(
      () => _client.post(
        _endpoint(state.serverUrl, '/api/family/places/upsert.php'),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json; charset=utf-8',
          'Authorization': 'Bearer ${state.deviceToken}',
        },
        body: jsonEncode({
          'device_id': state.deviceId,
          if (placeId != null && placeId.isNotEmpty) 'place_id': placeId,
          'name': name,
          'category': category.toWire(),
          'latitude': latitude,
          'longitude': longitude,
          'radius_meters': radiusMeters,
          'is_home': isHome,
          'notify_on_enter': notifyOnEnter,
          'notify_on_exit': notifyOnExit,
        }),
      ),
      FamilySnapshot.fromJson,
    );
  }

  Future<ApiResponse<FamilySnapshot>> deleteSavedPlace({
    required DeviceTrackerState state,
    required String placeId,
  }) async {
    if (state.isSupabaseMode) {
      return _execute<FamilySnapshot>(
        () => _client.post(
          _supabaseRpc(state.supabaseUrl, 'rpc_delete_saved_place'),
          headers: _supabaseHeaders(state.supabaseAnonKey),
          body: jsonEncode({
            'p_device_id': state.deviceId,
            'p_device_token': state.deviceToken,
            'p_place_id': placeId,
          }),
        ),
        FamilySnapshot.fromJson,
      );
    }
    return _execute<FamilySnapshot>(
      () => _client.post(
        _endpoint(state.serverUrl, '/api/family/places/delete.php'),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json; charset=utf-8',
          'Authorization': 'Bearer ${state.deviceToken}',
        },
        body: jsonEncode({
          'device_id': state.deviceId,
          'place_id': placeId,
        }),
      ),
      FamilySnapshot.fromJson,
    );
  }

  Future<ApiResponse<void>> deleteLocationForBackend(DeviceTrackerState state) async {
    if (state.isSupabaseMode) {
      return _execute<void>(
        () => _client.post(
          _supabaseRpc(state.supabaseUrl, 'rpc_delete_device_location'),
          headers: _supabaseHeaders(state.supabaseAnonKey),
          body: jsonEncode({
            'p_device_id': state.deviceId,
            'p_device_token': state.deviceToken,
          }),
        ),
        (_) {},
      );
    }
    return deleteStoredLocation(
      serverUrl: state.serverUrl,
      deviceId: state.deviceId,
      deviceToken: state.deviceToken,
    );
  }

  Future<ApiResponse<void>> unregisterForBackend(DeviceTrackerState state) async {
    if (state.isSupabaseMode) {
      return _execute<void>(
        () => _client.post(
          _supabaseRpc(state.supabaseUrl, 'rpc_unregister_device'),
          headers: _supabaseHeaders(state.supabaseAnonKey),
          body: jsonEncode({
            'p_device_id': state.deviceId,
            'p_device_token': state.deviceToken,
          }),
        ),
        (_) {},
      );
    }
    return unregisterDevice(
      serverUrl: state.serverUrl,
      deviceId: state.deviceId,
      deviceToken: state.deviceToken,
    );
  }

  Future<ApiResponse<T>> _execute<T>(
    Future<http.Response> Function() call,
    T Function(Map<String, dynamic> json) parser,
  ) async {
    try {
      final resp = await call().timeout(_timeout);
      Map<String, dynamic> decoded = const {};
      if (resp.body.isNotEmpty) {
        final raw = jsonDecode(resp.body);
        if (raw is Map<String, dynamic>) {
          decoded = raw;
        }
      }

      final successFlag = decoded['success'];
      if (resp.statusCode >= 200 &&
          resp.statusCode < 300 &&
          successFlag != false) {
        return ApiResponse<T>(
          ok: true,
          statusCode: resp.statusCode,
          data: parser(decoded),
        );
      }

      return ApiResponse<T>(
        ok: false,
        statusCode: resp.statusCode,
        error: (decoded['error'] as String?) ??
            'Server returned HTTP ${resp.statusCode}.',
        errorCode: decoded['error_code'] as String?,
      );
    } on SocketException catch (_) {
      return const ApiResponse(
        ok: false,
        statusCode: 0,
        error: 'Unable to connect to the server. Check network or server URL.',
        isNetworkError: true,
      );
    } on TimeoutException catch (_) {
      return const ApiResponse(
        ok: false,
        statusCode: 0,
        error: 'Connection timed out while contacting LocaShare server.',
        isNetworkError: true,
      );
    } on FormatException catch (_) {
      return const ApiResponse(
        ok: false,
        statusCode: 0,
        error: 'Invalid server URL or unexpected server response.',
      );
    } catch (_) {
      return const ApiResponse(
        ok: false,
        statusCode: 0,
        error: 'Network request failed.',
        isNetworkError: true,
      );
    }
  }

  static DateTime? _parseIso(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return DateTime.tryParse(value.trim())?.toUtc();
  }
}
