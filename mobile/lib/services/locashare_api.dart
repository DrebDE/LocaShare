import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

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
