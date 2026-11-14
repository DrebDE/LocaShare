import 'package:flutter/services.dart';

/// Platform abstraction over the Android foreground service & permission APIs.
abstract class NativeLocationBridge {
  Future<Map<String, dynamic>> getState();
  Future<Map<String, dynamic>> checkPermissions();
  Future<Map<String, dynamic>> requestLocationPermissions();
  Future<void> openAppSettings();
  Future<void> openLocationSettings();
  Future<Map<String, dynamic>> setServerUrl(String serverUrl);
  Future<Map<String, dynamic>> setIntervalMs(int intervalMs);
  Future<Map<String, dynamic>> configureDevice({
    required String serverUrl,
    required String deviceId,
    required String deviceToken,
    required String deviceName,
    required String statusState,
    required int updateIntervalMs,
  });
  Future<Map<String, dynamic>> startSharing();
  Future<Map<String, dynamic>> stopSharing();
  Future<Map<String, dynamic>> flushPendingNow();
  Future<Map<String, dynamic>> clearLocationMetadata();
  Future<Map<String, dynamic>> unregisterReset();
  Stream<Map<String, dynamic>> get stateStream;
}

class MethodChannelNativeBridge implements NativeLocationBridge {
  MethodChannelNativeBridge({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _methodChannel =
            methodChannel ?? const MethodChannel('com.locashare.app/location_service'),
        _eventChannel =
            eventChannel ?? const EventChannel('com.locashare.app/location_events');

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  Stream<Map<String, dynamic>>? _cachedStream;

  Map<String, dynamic> _normalize(Object? raw) {
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    return const {};
  }

  @override
  Future<Map<String, dynamic>> getState() async =>
      _normalize(await _methodChannel.invokeMethod<Object?>('getState'));

  @override
  Future<Map<String, dynamic>> checkPermissions() async =>
      _normalize(await _methodChannel.invokeMethod<Object?>('checkPermissions'));

  @override
  Future<Map<String, dynamic>> requestLocationPermissions() async => _normalize(
      await _methodChannel.invokeMethod<Object?>('requestLocationPermissions'));

  @override
  Future<void> openAppSettings() async {
    await _methodChannel.invokeMethod<Object?>('openAppSettings');
  }

  @override
  Future<void> openLocationSettings() async {
    await _methodChannel.invokeMethod<Object?>('openLocationSettings');
  }

  @override
  Future<Map<String, dynamic>> setServerUrl(String serverUrl) async =>
      _normalize(await _methodChannel.invokeMethod<Object?>(
        'setServerUrl',
        {'serverUrl': serverUrl},
      ));

  @override
  Future<Map<String, dynamic>> setIntervalMs(int intervalMs) async =>
      _normalize(await _methodChannel.invokeMethod<Object?>(
        'setIntervalMs',
        {'intervalMs': intervalMs},
      ));

  @override
  Future<Map<String, dynamic>> configureDevice({
    required String serverUrl,
    required String deviceId,
    required String deviceToken,
    required String deviceName,
    required String statusState,
    required int updateIntervalMs,
  }) async =>
      _normalize(await _methodChannel.invokeMethod<Object?>(
        'configureDevice',
        {
          'serverUrl': serverUrl,
          'deviceId': deviceId,
          'deviceToken': deviceToken,
          'deviceName': deviceName,
          'statusState': statusState,
          'updateIntervalMs': updateIntervalMs,
        },
      ));

  @override
  Future<Map<String, dynamic>> startSharing() async =>
      _normalize(await _methodChannel.invokeMethod<Object?>('startSharing'));

  @override
  Future<Map<String, dynamic>> stopSharing() async =>
      _normalize(await _methodChannel.invokeMethod<Object?>('stopSharing'));

  @override
  Future<Map<String, dynamic>> flushPendingNow() async =>
      _normalize(await _methodChannel.invokeMethod<Object?>('flushPendingNow'));

  @override
  Future<Map<String, dynamic>> clearLocationMetadata() async => _normalize(
      await _methodChannel.invokeMethod<Object?>('clearLocationMetadata'));

  @override
  Future<Map<String, dynamic>> unregisterReset() async =>
      _normalize(await _methodChannel.invokeMethod<Object?>('unregisterReset'));

  @override
  Stream<Map<String, dynamic>> get stateStream {
    _cachedStream ??= _eventChannel
        .receiveBroadcastStream()
        .map((event) => _normalize(event));
    return _cachedStream!;
  }
}
