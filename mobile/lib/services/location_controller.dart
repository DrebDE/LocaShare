import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/device_state.dart';
import '../models/family_models.dart';
import '../services/locashare_api.dart';
import '../services/native_bridge.dart';

/// Application state controller coordinating registration, one-time pairing codes,
/// Family Circles, Saved Places (Home/School/Work), Smart Home geofencing,
/// permission gating, foreground sharing, and Supabase/PHP backend sync.
class LocationController extends ChangeNotifier {
  LocationController({
    required this._api,
    required this._bridge,
    bool enableBackgroundTimers = true,
  }) : _enableTimers = enableBackgroundTimers;

  final LocaShareApi _api;
  final NativeLocationBridge _bridge;
  final bool _enableTimers;

  DeviceTrackerState _state = const DeviceTrackerState();
  DeviceTrackerState get state => _state;

  FamilySnapshot _family = const FamilySnapshot();
  FamilySnapshot get family => _family;

  String? _selectedMemberDeviceId;
  String? get selectedMemberDeviceId => _selectedMemberDeviceId;

  StreamSubscription<Map<String, dynamic>>? _nativeSub;
  Timer? _countdownTimer;
  Timer? _statusPollTimer;
  String? _statusMessage;
  String? get statusMessage => _statusMessage;

  Future<void> initialize() async {
    try {
      final raw = await _bridge.getState();
      _applyNativeSnapshot(raw);
    } catch (_) {
      // Keep safe defaults when running on unsupported test hosts
    }

    try {
      _nativeSub ??= _bridge.stateStream.listen(_applyNativeSnapshot);
    } catch (_) {}

    if (_enableTimers) {
      _countdownTimer ??= Timer.periodic(
        const Duration(seconds: 1),
        (_) {
          if (_state.pairingExpiresAt != null) {
            notifyListeners();
          }
        },
      );
      _statusPollTimer ??= Timer.periodic(
        const Duration(seconds: 15),
        (_) {
          if (_state.isRegistered) {
            if (!_state.isSupabaseMode) {
              refreshServerStatus(quiet: true);
            }
            refreshFamilySnapshot(quiet: true);
          }
        },
      );
    }

    if (_state.isRegistered) {
      if (!_state.isSupabaseMode) {
        await refreshServerStatus(quiet: true);
      }
      await refreshFamilySnapshot(quiet: true);
    }
  }

  void selectFamilyMember(String? deviceId) {
    _selectedMemberDeviceId = deviceId;
    notifyListeners();
  }

  void _applyNativeSnapshot(Map<String, dynamic> raw) {
    if (raw.isEmpty) return;
    final hasDeviceId = (raw['deviceId'] as String?)?.isNotEmpty ?? false;
    var parsedState = PhoneStatusState.fromWire(raw['statusState'] as String?);
    final isSharing = raw['isSharing'] == true;
    final hasPerm = raw['hasLocationPermission'] as bool? ?? _state.hasLocationPermission;

    if (hasDeviceId && !hasPerm && parsedState != PhoneStatusState.waitingForPairing) {
      parsedState = PhoneStatusState.permissionMissing;
    } else if (!hasDeviceId) {
      parsedState = PhoneStatusState.unregistered;
    }

    final nextServerUrl = (raw['serverUrl'] as String?)?.trim();
    final nextSupaUrl = (raw['supabaseUrl'] as String?)?.trim();
    final nextSupaKey = (raw['supabaseAnonKey'] as String?)?.trim();
    final nextDeviceName = (raw['deviceName'] as String?)?.trim();
    final defaultName = (raw['defaultDeviceName'] as String?)?.trim();

    _state = _state.copyWith(
      backendMode: raw.containsKey('backendMode')
          ? BackendMode.fromWire(raw['backendMode'] as String?)
          : _state.backendMode,
      serverUrl: (nextServerUrl != null && nextServerUrl.isNotEmpty)
          ? nextServerUrl
          : _state.serverUrl,
      supabaseUrl: nextSupaUrl ?? _state.supabaseUrl,
      supabaseAnonKey: nextSupaKey ?? _state.supabaseAnonKey,
      deviceId: (raw['deviceId'] as String?) ?? _state.deviceId,
      deviceToken: (raw['deviceToken'] as String?) ?? _state.deviceToken,
      deviceName: (nextDeviceName != null && nextDeviceName.isNotEmpty)
          ? nextDeviceName
          : ((defaultName != null && defaultName.isNotEmpty)
              ? defaultName
              : _state.deviceName),
      isSharing: isSharing,
      statusState: parsedState,
      smartHomeMode: raw['smartHomeMode'] as bool? ?? _state.smartHomeMode,
      presenceMode: raw.containsKey('presenceMode')
          ? PresenceMode.fromWire(raw['presenceMode'] as String?)
          : _state.presenceMode,
      currentPlaceId: raw.containsKey('currentPlaceId')
          ? raw['currentPlaceId'] as String?
          : _state.currentPlaceId,
      currentPlaceName: raw.containsKey('currentPlaceName')
          ? raw['currentPlaceName'] as String?
          : _state.currentPlaceName,
      homePrivacyMasked: raw['homePrivacyMasked'] as bool? ?? _state.homePrivacyMasked,
      lastLatitude: (raw['lastLatitude'] as num?)?.toDouble() ?? _state.lastLatitude,
      lastLongitude: (raw['lastLongitude'] as num?)?.toDouble() ?? _state.lastLongitude,
      circleId: (raw['circleId'] as String?) ?? _state.circleId,
      circleName: (raw['circleName'] as String?) ?? _state.circleName,
      memberName: (raw['memberName'] as String?) ?? _state.memberName,
      updateIntervalMs:
          (raw['updateIntervalMs'] as num?)?.toInt() ?? _state.updateIntervalMs,
      lastUploadAt: DeviceTrackerState.parseIsoDate(raw['lastUploadAt']) ??
          _state.lastUploadAt,
      lastFixAt: DeviceTrackerState.parseIsoDate(raw['lastFixAt']) ??
          _state.lastFixAt,
      lastAccuracyMeters: (raw['lastAccuracy'] as num?)?.toDouble() ??
          _state.lastAccuracyMeters,
      lastError: raw['lastError'] as String?,
      clearLastError: raw['lastError'] == null,
      hasPendingFix: raw['hasPendingFix'] == true,
      pendingRecordedAt:
          DeviceTrackerState.parseIsoDate(raw['pendingRecordedAt']),
      clearPendingRecordedAt: raw['pendingRecordedAt'] == null,
      hasLocationPermission: hasPerm,
      hasFineLocation: raw['hasFineLocation'] as bool? ?? _state.hasFineLocation,
      hasNotificationPermission:
          raw['hasNotificationPermission'] as bool? ?? _state.hasNotificationPermission,
      isLocationServiceEnabled:
          raw['isLocationServiceEnabled'] as bool? ?? _state.isLocationServiceEnabled,
      isNetworkConnected:
          raw['isNetworkConnected'] as bool? ?? _state.isNetworkConnected,
      networkType: (raw['networkType'] as String?) ?? _state.networkType,
    );
    notifyListeners();
  }

  Future<bool> saveServerUrl(String url) async {
    final trimmed = url.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !uri.hasScheme ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      _setFeedback(error: 'Enter a valid http:// or https:// server URL.');
      return false;
    }

    _state = _state.copyWith(
      backendMode: BackendMode.php,
      serverUrl: trimmed,
      clearLastError: true,
    );
    _statusMessage = 'Saved server URL.';
    notifyListeners();
    try {
      await _bridge.setBackendConfig(
        backendMode: 'php',
        serverUrl: trimmed,
        supabaseUrl: _state.supabaseUrl,
        supabaseAnonKey: _state.supabaseAnonKey,
      );
    } catch (_) {}
    return true;
  }

  Future<bool> saveBackendConfig({
    required BackendMode mode,
    String? serverUrl,
    String? supabaseUrl,
    String? supabaseAnonKey,
  }) async {
    final nextServer = (serverUrl ?? _state.serverUrl).trim().replaceAll(RegExp(r'/+$'), '');
    final nextSupaUrl = (supabaseUrl ?? _state.supabaseUrl).trim().replaceAll(RegExp(r'/+$'), '');
    final nextSupaKey = (supabaseAnonKey ?? _state.supabaseAnonKey).trim();

    if (mode == BackendMode.supabase) {
      final uri = Uri.tryParse(nextSupaUrl);
      if (uri == null || uri.scheme.toLowerCase() != 'https' || uri.host.isEmpty) {
        _setFeedback(error: 'Enter a valid https:// Supabase Project URL.');
        return false;
      }
      if (nextSupaKey.length < 16) {
        _setFeedback(error: 'Enter your Supabase anon public key.');
        return false;
      }
    } else {
      final uri = Uri.tryParse(nextServer);
      if (uri == null ||
          !uri.hasScheme ||
          !(uri.scheme == 'http' || uri.scheme == 'https') ||
          uri.host.isEmpty) {
        _setFeedback(error: 'Enter a valid http:// or https:// server URL.');
        return false;
      }
    }

    _state = _state.copyWith(
      backendMode: mode,
      serverUrl: nextServer,
      supabaseUrl: nextSupaUrl,
      supabaseAnonKey: nextSupaKey,
      clearLastError: true,
    );
    _statusMessage = 'Switched backend to ${mode.displayLabel}.';
    notifyListeners();
    try {
      await _bridge.setBackendConfig(
        backendMode: mode.toWire(),
        serverUrl: nextServer,
        supabaseUrl: nextSupaUrl,
        supabaseAnonKey: nextSupaKey,
      );
    } catch (_) {}
    return true;
  }

  Future<bool> checkServerConnection() async {
    _setBusy('Checking backend...');
    final res = await _api.checkBackendHealth(_state);
    _clearBusy();
    if (res.ok) {
      _setFeedback(message: 'Connected cleanly to ${_state.backendMode.displayLabel}.');
      return true;
    }
    _setFeedback(error: res.error ?? 'Unable to reach backend server.');
    return false;
  }

  Future<bool> registerDevice({String? customDeviceName}) async {
    final targetName = (customDeviceName?.trim().isNotEmpty ?? false)
        ? customDeviceName!.trim()
        : _state.deviceName;

    _setBusy('Registering device...');
    final res = await _api.registerDeviceForBackend(
      state: _state,
      deviceName: targetName,
    );

    if (!res.ok || res.data == null) {
      _clearBusy();
      _setFeedback(error: res.error ?? 'Device registration failed.');
      return false;
    }

    final data = res.data!;
    final permCheck = await _safeCheckPermissions();
    final hasPerm = permCheck['hasLocationPermission'] as bool? ??
        _state.hasLocationPermission;

    final nextState = _state.isSupabaseMode
        ? (hasPerm ? PhoneStatusState.registered : PhoneStatusState.permissionMissing)
        : PhoneStatusState.waitingForPairing;

    _state = _state.copyWith(
      deviceId: data.deviceId,
      deviceName: data.deviceName,
      deviceToken: data.deviceToken,
      pairingCode: data.pairingCode.isNotEmpty ? data.pairingCode : null,
      clearPairingCode: data.pairingCode.isEmpty,
      pairingQrPayload: data.pairingQrPayload.isNotEmpty ? data.pairingQrPayload : null,
      pairingExpiresAt: data.pairingExpiresAt,
      clearPairingExpiry: data.pairingExpiresAt == null,
      pairedDashboardsCount: 0,
      isSharing: false,
      statusState: nextState,
      hasLocationPermission: hasPerm,
      clearLastError: true,
      clearBusyAction: true,
    );
    _statusMessage = _state.isSupabaseMode
        ? 'Device registered on Supabase Cloud. Create or join a Family Circle!'
        : 'Device registered. Create/join a Family Circle or pair with your laptop dashboard.';
    notifyListeners();

    await _bridge.configureDevice(
      serverUrl: _state.serverUrl,
      deviceId: data.deviceId,
      deviceToken: data.deviceToken,
      deviceName: data.deviceName,
      statusState: _state.statusState.toWire(),
      updateIntervalMs: _state.updateIntervalMs,
    );
    return true;
  }

  Future<bool> refreshPairingCode() async {
    if (!_state.isRegistered || _state.isSupabaseMode) return false;
    _setBusy('Generating new pairing code...');
    final res = await _api.generatePairingCode(
      serverUrl: _state.serverUrl,
      deviceId: _state.deviceId,
      deviceToken: _state.deviceToken,
    );
    _clearBusy();

    if (!res.ok || res.data == null) {
      if (res.statusCode == 401 && res.errorCode == 'DEVICE_UNREGISTERED') {
        await _handleRemoteUnregistered(res.error);
        return false;
      }
      _setFeedback(error: res.error ?? 'Could not generate a new pairing code.');
      return false;
    }

    final data = res.data!;
    _state = _state.copyWith(
      pairingCode: data.pairingCode,
      pairingQrPayload: data.pairingQrPayload,
      pairingExpiresAt: data.pairingExpiresAt,
      pairedDashboardsCount: data.pairedDashboardsCount,
      clearLastError: true,
    );
    _statusMessage = 'Generated a new one-time pairing code.';
    notifyListeners();
    return true;
  }

  Future<void> refreshServerStatus({bool quiet = false}) async {
    if (!_state.isRegistered || _state.isSupabaseMode) return;
    final res = await _api.fetchStatus(
      serverUrl: _state.serverUrl,
      deviceId: _state.deviceId,
      deviceToken: _state.deviceToken,
    );

    if (!res.ok || res.data == null) {
      if (res.statusCode == 401 && res.errorCode == 'DEVICE_UNREGISTERED') {
        await _handleRemoteUnregistered(res.error);
        return;
      }
      if (!quiet) {
        _setFeedback(error: res.error ?? 'Could not check server status.');
      }
      return;
    }

    final status = res.data!;
    var nextPhoneState = _state.statusState;
    if (status.pairedDashboardsCount > 0 &&
        nextPhoneState == PhoneStatusState.waitingForPairing) {
      nextPhoneState = _state.hasLocationPermission
          ? PhoneStatusState.registered
          : PhoneStatusState.permissionMissing;
    } else if (status.pairedDashboardsCount == 0 && !_state.isSharing) {
      nextPhoneState = PhoneStatusState.waitingForPairing;
    }

    _state = _state.copyWith(
      pairedDashboardsCount: status.pairedDashboardsCount,
      statusState: nextPhoneState,
      clearLastError: quiet ? false : true,
    );
    notifyListeners();
  }

  // ── Family Circles, Saved Places & Smart Home Geofencing ──────

  Future<bool> createFamilyCircle({
    required String circleName,
    String? memberName,
  }) async {
    if (!_state.isRegistered) {
      _setFeedback(error: 'Register this device first.');
      return false;
    }
    _setBusy('Creating family circle...');
    final res = await _api.createFamilyCircle(
      state: _state,
      circleName: circleName.trim().isEmpty ? 'Our Family' : circleName.trim(),
      memberName: (memberName ?? '').trim().isEmpty
          ? _state.deviceName
          : memberName!.trim(),
    );
    _clearBusy();

    if (!res.ok || res.data == null) {
      _setFeedback(error: res.error ?? 'Could not create family circle.');
      return false;
    }

    await _applyFamilySnapshot(res.data!);
    _statusMessage = 'Created "${res.data!.circle?.name ?? circleName}". Share your invite code with family!';
    notifyListeners();
    return true;
  }

  Future<bool> joinFamilyCircle({
    required String inviteCode,
    String? memberName,
  }) async {
    if (!_state.isRegistered) {
      _setFeedback(error: 'Register this device first.');
      return false;
    }
    _setBusy('Joining family circle...');
    final res = await _api.joinFamilyCircle(
      state: _state,
      inviteCode: inviteCode.trim(),
      memberName: (memberName ?? '').trim().isEmpty
          ? _state.deviceName
          : memberName!.trim(),
    );
    _clearBusy();

    if (!res.ok || res.data == null) {
      _setFeedback(error: res.error ?? 'Invite code not found.');
      return false;
    }

    await _applyFamilySnapshot(res.data!);
    _statusMessage = 'Joined "${res.data!.circle?.name ?? 'Family Circle'}"!';
    notifyListeners();
    return true;
  }

  Future<bool> leaveFamilyCircle() async {
    if (!_state.isRegistered) return false;
    _setBusy('Leaving circle...');
    final res = await _api.leaveFamilyCircle(_state);
    _clearBusy();
    if (!res.ok) {
      _setFeedback(error: res.error ?? 'Failed to leave circle.');
      return false;
    }
    _family = const FamilySnapshot();
    _selectedMemberDeviceId = null;
    _state = _state.copyWith(
      circleId: '',
      circleName: '',
      memberName: '',
      clearLastError: true,
    );
    try {
      await _bridge.setCircleInfo(circleId: '', circleName: '', memberName: '');
      await _bridge.setSavedPlacesJson('[]');
    } catch (_) {}
    _statusMessage = 'Left family circle.';
    notifyListeners();
    return true;
  }

  Future<bool> regenerateCircleInviteCode() async {
    if (!_state.isRegistered) return false;
    _setBusy('Rotating invite code...');
    final res = await _api.regenerateCircleInvite(_state);
    _clearBusy();
    if (!res.ok || res.data == null || res.data!.isEmpty) {
      _setFeedback(error: res.error ?? 'Could not regenerate invite code.');
      return false;
    }
    await refreshFamilySnapshot(quiet: true);
    _statusMessage = 'Generated a new family invite code.';
    notifyListeners();
    return true;
  }

  Future<void> refreshFamilySnapshot({bool quiet = false}) async {
    if (!_state.isRegistered) return;
    final res = await _api.fetchCircleSnapshot(_state);
    if (!res.ok || res.data == null) {
      if (!quiet) {
        _setFeedback(error: res.error ?? 'Failed to refresh family circle.');
      }
      return;
    }
    await _applyFamilySnapshot(res.data!);
  }

  Future<bool> upsertSavedPlace({
    String? placeId,
    required String name,
    required PlaceCategory category,
    required double latitude,
    required double longitude,
    required int radiusMeters,
    required bool notifyOnEnter,
    required bool notifyOnExit,
  }) async {
    if (!_state.isRegistered || _family.circle == null) {
      _setFeedback(error: 'Create or join a Family Circle before adding places.');
      return false;
    }
    _setBusy('Saving place...');
    final res = await _api.upsertSavedPlace(
      state: _state,
      placeId: placeId,
      name: name.trim(),
      category: category,
      latitude: latitude,
      longitude: longitude,
      radiusMeters: radiusMeters,
      isHome: category == PlaceCategory.home,
      notifyOnEnter: notifyOnEnter,
      notifyOnExit: notifyOnExit,
    );
    _clearBusy();
    if (!res.ok || res.data == null) {
      _setFeedback(error: res.error ?? 'Failed to save place.');
      return false;
    }
    await _applyFamilySnapshot(res.data!);
    _statusMessage = 'Saved "${name.trim()}" (${radiusMeters}m geofence).';
    notifyListeners();
    return true;
  }

  Future<bool> deleteSavedPlace(String placeId) async {
    if (!_state.isRegistered) return false;
    _setBusy('Deleting place...');
    final res = await _api.deleteSavedPlace(state: _state, placeId: placeId);
    _clearBusy();
    if (!res.ok || res.data == null) {
      _setFeedback(error: res.error ?? 'Failed to delete place.');
      return false;
    }
    await _applyFamilySnapshot(res.data!);
    _statusMessage = 'Deleted saved place.';
    notifyListeners();
    return true;
  }

  Future<void> setSmartHomeMode(bool enabled) async {
    _state = _state.copyWith(smartHomeMode: enabled);
    _statusMessage = enabled
        ? 'Smart Home Mode enabled (Battery saver + privacy at Home, live GPS when away).'
        : 'Always Live GPS enabled everywhere.';
    notifyListeners();
    try {
      final nextSnap = await _bridge.setSmartHomeMode(enabled);
      _applyNativeSnapshot(nextSnap);
    } catch (_) {}
  }

  Future<({double lat, double lng})?> getCurrentCoordinates() async {
    try {
      final raw = await _bridge.getCurrentLocation();
      final lat = (raw['latitude'] as num?)?.toDouble();
      final lng = (raw['longitude'] as num?)?.toDouble();
      if (lat != null && lng != null) {
        return (lat: lat, lng: lng);
      }
    } catch (_) {}
    if (_state.lastLatitude != null && _state.lastLongitude != null) {
      return (lat: _state.lastLatitude!, lng: _state.lastLongitude!);
    }
    return null;
  }

  Future<void> _applyFamilySnapshot(FamilySnapshot snapshot) async {
    _family = snapshot;
    final circle = snapshot.circle;
    _state = _state.copyWith(
      circleId: circle?.circleId ?? '',
      circleName: circle?.name ?? '',
      memberName: circle?.myMemberName ?? '',
    );

    if (_selectedMemberDeviceId == null && snapshot.members.isNotEmpty) {
      _selectedMemberDeviceId = snapshot.members.first.deviceId;
    }

    try {
      await _bridge.setCircleInfo(
        circleId: circle?.circleId ?? '',
        circleName: circle?.name ?? '',
        memberName: circle?.myMemberName ?? '',
      );
      await _bridge.setSavedPlacesJson(
        jsonEncode(snapshot.places.map((p) => p.toJson()).toList()),
      );
    } catch (_) {}
    notifyListeners();
  }

  Future<bool> requestPermissionsFromOs() async {
    _setBusy('Requesting permissions...');
    final perms = await _bridge.requestLocationPermissions();
    final hasLoc = perms['hasLocationPermission'] == true;
    final hasFine = perms['hasFineLocation'] == true;
    final hasNotif = perms['hasNotificationPermission'] as bool? ?? true;
    final locEnabled = perms['isLocationServiceEnabled'] as bool? ?? true;

    _state = _state.copyWith(
      hasLocationPermission: hasLoc,
      hasFineLocation: hasFine,
      hasNotificationPermission: hasNotif,
      isLocationServiceEnabled: locEnabled,
      statusState: !hasLoc && _state.isRegistered
          ? PhoneStatusState.permissionMissing
          : (_state.statusState == PhoneStatusState.permissionMissing && _state.isRegistered
              ? PhoneStatusState.registered
              : _state.statusState),
      lastError: hasLoc ? null : 'Location permission was denied.',
      clearLastError: hasLoc,
      clearBusyAction: true,
    );

    if (hasLoc) {
      _statusMessage = 'Location permission granted. Tap "Start sharing" whenever ready.';
    }
    notifyListeners();

    if (!hasLoc && _state.isRegistered && !_state.isSupabaseMode) {
      await _api.sendHeartbeat(
        serverUrl: _state.serverUrl,
        deviceId: _state.deviceId,
        deviceToken: _state.deviceToken,
        sharingEnabled: false,
        statusState: 'permission_missing',
      );
    }
    return hasLoc;
  }

  Future<void> openAppSettings() => _bridge.openAppSettings();
  Future<void> openLocationSettings() => _bridge.openLocationSettings();

  Future<void> setUpdateIntervalMs(int intervalMs) async {
    _state = _state.copyWith(updateIntervalMs: intervalMs);
    _statusMessage =
        'Updated sharing interval to ${(intervalMs / 1000).round()} seconds.';
    notifyListeners();
    final snap = await _bridge.setIntervalMs(intervalMs);
    _applyNativeSnapshot(snap);
  }

  Future<bool> startSharing() async {
    if (!_state.isRegistered) {
      _setFeedback(error: 'Register this device before starting sharing.');
      return false;
    }

    final perms = await _safeCheckPermissions();
    final hasLoc = perms['hasLocationPermission'] == true;
    final locEnabled = perms['isLocationServiceEnabled'] as bool? ?? true;
    if (!hasLoc) {
      _state = _state.copyWith(
        isSharing: false,
        statusState: PhoneStatusState.permissionMissing,
        hasLocationPermission: false,
        lastError: 'Location permission is required before sharing can start.',
      );
      notifyListeners();
      return false;
    }

    if (!locEnabled) {
      _state = _state.copyWith(
        hasLocationPermission: true,
        isLocationServiceEnabled: false,
        lastError: 'Turn on device Location (GPS) in Android settings first.',
      );
      notifyListeners();
      return false;
    }

    _setBusy('Starting foreground sharing service...');
    final nextSnap = await _bridge.startSharing();
    _state = _state.copyWith(
      isSharing: true,
      statusState: _state.isNetworkConnected
          ? PhoneStatusState.sharing
          : PhoneStatusState.offline,
      clearLastError: true,
      clearBusyAction: true,
    );
    _statusMessage = 'Foreground location sharing is active.';
    _applyNativeSnapshot(nextSnap);
    return true;
  }

  Future<void> stopSharing() async {
    _setBusy('Stopping sharing...');
    final nextSnap = await _bridge.stopSharing();
    _state = _state.copyWith(
      isSharing: false,
      statusState: _state.isRegistered
          ? PhoneStatusState.paused
          : PhoneStatusState.unregistered,
      clearBusyAction: true,
      clearLastError: true,
    );
    _statusMessage = 'Location sharing paused.';
    _applyNativeSnapshot(nextSnap);
  }

  Future<bool> revokeDashboardPairings() async {
    if (!_state.isRegistered || _state.isSupabaseMode) return false;
    _setBusy('Revoking paired dashboards...');
    if (_state.isSharing) {
      await _bridge.stopSharing();
    }
    final res = await _api.revokeAllPairings(
      serverUrl: _state.serverUrl,
      deviceId: _state.deviceId,
      deviceToken: _state.deviceToken,
      clearLocation: true,
    );
    _clearBusy();

    if (!res.ok) {
      _setFeedback(error: res.error ?? 'Failed to revoke dashboard pairings.');
      return false;
    }

    await _bridge.clearLocationMetadata();
    _state = _state.copyWith(
      isSharing: false,
      pairedDashboardsCount: 0,
      statusState: PhoneStatusState.waitingForPairing,
      clearLastUploadAt: true,
      clearLastFixAt: true,
      clearLastAccuracy: true,
      clearLastCoords: true,
      hasPendingFix: false,
      clearPendingRecordedAt: true,
      clearLastError: true,
    );
    _statusMessage =
        'Revoked all dashboard pairings and cleared stored server location.';
    notifyListeners();
    return true;
  }

  Future<bool> deleteStoredLocation() async {
    if (!_state.isRegistered) return false;
    _setBusy('Deleting stored location...');
    final res = await _api.deleteLocationForBackend(_state);
    _clearBusy();

    if (!res.ok) {
      _setFeedback(error: res.error ?? 'Failed to delete stored location.');
      return false;
    }

    await _bridge.clearLocationMetadata();
    _state = _state.copyWith(
      presenceMode: PresenceMode.unknown,
      clearCurrentPlaceId: true,
      clearCurrentPlaceName: true,
      homePrivacyMasked: false,
      clearLastUploadAt: true,
      clearLastFixAt: true,
      clearLastAccuracy: true,
      clearLastCoords: true,
      hasPendingFix: false,
      clearPendingRecordedAt: true,
      clearLastError: true,
    );
    _statusMessage = 'Deleted stored location from the server.';
    notifyListeners();
    await refreshFamilySnapshot(quiet: true);
    return true;
  }

  Future<bool> unregisterDevice() async {
    if (!_state.isRegistered) return false;
    _setBusy('Unregistering device...');
    if (_state.isSharing) {
      await _bridge.stopSharing();
    }

    final res = await _api.unregisterForBackend(_state);

    if (!res.ok && res.statusCode != 401) {
      _clearBusy();
      _setFeedback(
        error: res.error ??
            'Could not contact server to unregister. Check connection before retrying.',
      );
      return false;
    }

    await _bridge.unregisterReset();
    _family = const FamilySnapshot();
    _selectedMemberDeviceId = null;
    _state = DeviceTrackerState(
      backendMode: _state.backendMode,
      serverUrl: _state.serverUrl,
      supabaseUrl: _state.supabaseUrl,
      supabaseAnonKey: _state.supabaseAnonKey,
      smartHomeMode: _state.smartHomeMode,
      deviceName: _state.deviceName,
      hasLocationPermission: _state.hasLocationPermission,
      hasFineLocation: _state.hasFineLocation,
      hasNotificationPermission: _state.hasNotificationPermission,
      isLocationServiceEnabled: _state.isLocationServiceEnabled,
      isNetworkConnected: _state.isNetworkConnected,
      networkType: _state.networkType,
    );
    _statusMessage =
        'Device unregistered and all stored location data was removed.';
    notifyListeners();
    return true;
  }

  Future<Map<String, dynamic>> _safeCheckPermissions() async {
    try {
      return await _bridge.checkPermissions();
    } catch (_) {
      return const {};
    }
  }

  Future<void> _handleRemoteUnregistered(String? serverError) async {
    await _bridge.unregisterReset();
    _family = const FamilySnapshot();
    _selectedMemberDeviceId = null;
    _state = DeviceTrackerState(
      backendMode: _state.backendMode,
      serverUrl: _state.serverUrl,
      supabaseUrl: _state.supabaseUrl,
      supabaseAnonKey: _state.supabaseAnonKey,
      smartHomeMode: _state.smartHomeMode,
      deviceName: _state.deviceName,
      hasLocationPermission: _state.hasLocationPermission,
      hasFineLocation: _state.hasFineLocation,
      hasNotificationPermission: _state.hasNotificationPermission,
      isLocationServiceEnabled: _state.isLocationServiceEnabled,
      lastError: serverError ?? 'Device registration is no longer active on the server.',
    );
    notifyListeners();
  }

  void _setBusy(String label) {
    _state = _state.copyWith(busyAction: label);
    notifyListeners();
  }

  void _clearBusy() {
    _state = _state.copyWith(clearBusyAction: true);
  }

  void _setFeedback({String? message, String? error}) {
    _statusMessage = message;
    _state = _state.copyWith(
      lastError: error,
      clearLastError: error == null,
      clearBusyAction: true,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _statusPollTimer?.cancel();
    _nativeSub?.cancel();
    super.dispose();
  }
}
