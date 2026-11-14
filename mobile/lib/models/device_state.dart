/// Immutable state models for the LocaShare Android app.
library;

enum PhoneStatusState {
  unregistered,
  waitingForPairing,
  registered,
  sharing,
  paused,
  noGpsFix,
  offline,
  permissionMissing;

  static PhoneStatusState fromWire(String? raw) {
    switch (raw?.trim()) {
      case 'waiting_for_pairing':
        return PhoneStatusState.waitingForPairing;
      case 'registered':
        return PhoneStatusState.registered;
      case 'sharing':
        return PhoneStatusState.sharing;
      case 'paused':
        return PhoneStatusState.paused;
      case 'no_gps_fix':
        return PhoneStatusState.noGpsFix;
      case 'offline':
        return PhoneStatusState.offline;
      case 'permission_missing':
        return PhoneStatusState.permissionMissing;
      default:
        return PhoneStatusState.unregistered;
    }
  }

  String toWire() {
    switch (this) {
      case PhoneStatusState.unregistered:
        return 'unregistered';
      case PhoneStatusState.waitingForPairing:
        return 'waiting_for_pairing';
      case PhoneStatusState.registered:
        return 'registered';
      case PhoneStatusState.sharing:
        return 'sharing';
      case PhoneStatusState.paused:
        return 'paused';
      case PhoneStatusState.noGpsFix:
        return 'no_gps_fix';
      case PhoneStatusState.offline:
        return 'offline';
      case PhoneStatusState.permissionMissing:
        return 'permission_missing';
    }
  }

  String get displayLabel {
    switch (this) {
      case PhoneStatusState.unregistered:
        return 'Not Registered';
      case PhoneStatusState.waitingForPairing:
        return 'Waiting for Pairing';
      case PhoneStatusState.registered:
        return 'Registered (Ready)';
      case PhoneStatusState.sharing:
        return 'Sharing Live';
      case PhoneStatusState.paused:
        return 'Paused';
      case PhoneStatusState.noGpsFix:
        return 'No GPS Fix';
      case PhoneStatusState.offline:
        return 'Offline';
      case PhoneStatusState.permissionMissing:
        return 'Permission Missing';
    }
  }
}

class DeviceTrackerState {
  const DeviceTrackerState({
    this.serverUrl = 'http://10.0.2.2:8080',
    this.deviceId = '',
    this.deviceToken = '',
    this.deviceName = 'Android Phone',
    this.statusState = PhoneStatusState.unregistered,
    this.isSharing = false,
    this.pairingCode,
    this.pairingQrPayload,
    this.pairingExpiresAt,
    this.pairedDashboardsCount = 0,
    this.updateIntervalMs = 30000,
    this.lastUploadAt,
    this.lastFixAt,
    this.lastAccuracyMeters,
    this.lastError,
    this.hasPendingFix = false,
    this.pendingRecordedAt,
    this.hasLocationPermission = false,
    this.hasFineLocation = false,
    this.hasNotificationPermission = true,
    this.isLocationServiceEnabled = true,
    this.isNetworkConnected = true,
    this.networkType = 'unknown',
    this.busyAction,
  });

  final String serverUrl;
  final String deviceId;
  final String deviceToken;
  final String deviceName;
  final PhoneStatusState statusState;
  final bool isSharing;
  final String? pairingCode;
  final String? pairingQrPayload;
  final DateTime? pairingExpiresAt;
  final int pairedDashboardsCount;
  final int updateIntervalMs;
  final DateTime? lastUploadAt;
  final DateTime? lastFixAt;
  final double? lastAccuracyMeters;
  final String? lastError;
  final bool hasPendingFix;
  final DateTime? pendingRecordedAt;
  final bool hasLocationPermission;
  final bool hasFineLocation;
  final bool hasNotificationPermission;
  final bool isLocationServiceEnabled;
  final bool isNetworkConnected;
  final String networkType;
  final String? busyAction;

  bool get isRegistered => deviceId.isNotEmpty && deviceToken.isNotEmpty;
  bool get isBusy => busyAction != null && busyAction!.isNotEmpty;

  bool get isHttpsUrl {
    final uri = Uri.tryParse(serverUrl.trim());
    return uri != null && uri.scheme.toLowerCase() == 'https';
  }

  bool get isLocalDevUrl {
    final uri = Uri.tryParse(serverUrl.trim());
    final host = uri?.host.toLowerCase() ?? '';
    return host == 'localhost' || host == '127.0.0.1' || host == '10.0.2.2';
  }

  int get pairingSecondsRemaining {
    final exp = pairingExpiresAt;
    if (exp == null) return 0;
    final diff = exp.difference(DateTime.now().toUtc()).inSeconds;
    return diff > 0 ? diff : 0;
  }

  bool get hasActivePairingCode =>
      pairingCode != null &&
      pairingCode!.isNotEmpty &&
      pairingSecondsRemaining > 0;

  DeviceTrackerState copyWith({
    String? serverUrl,
    String? deviceId,
    String? deviceToken,
    String? deviceName,
    PhoneStatusState? statusState,
    bool? isSharing,
    String? pairingCode,
    bool clearPairingCode = false,
    String? pairingQrPayload,
    DateTime? pairingExpiresAt,
    bool clearPairingExpiry = false,
    int? pairedDashboardsCount,
    int? updateIntervalMs,
    DateTime? lastUploadAt,
    bool clearLastUploadAt = false,
    DateTime? lastFixAt,
    bool clearLastFixAt = false,
    double? lastAccuracyMeters,
    bool clearLastAccuracy = false,
    String? lastError,
    bool clearLastError = false,
    bool? hasPendingFix,
    DateTime? pendingRecordedAt,
    bool clearPendingRecordedAt = false,
    bool? hasLocationPermission,
    bool? hasFineLocation,
    bool? hasNotificationPermission,
    bool? isLocationServiceEnabled,
    bool? isNetworkConnected,
    String? networkType,
    String? busyAction,
    bool clearBusyAction = false,
  }) {
    return DeviceTrackerState(
      serverUrl: serverUrl ?? this.serverUrl,
      deviceId: deviceId ?? this.deviceId,
      deviceToken: deviceToken ?? this.deviceToken,
      deviceName: deviceName ?? this.deviceName,
      statusState: statusState ?? this.statusState,
      isSharing: isSharing ?? this.isSharing,
      pairingCode: clearPairingCode ? null : (pairingCode ?? this.pairingCode),
      pairingQrPayload:
          clearPairingCode ? null : (pairingQrPayload ?? this.pairingQrPayload),
      pairingExpiresAt: clearPairingExpiry
          ? null
          : (pairingExpiresAt ?? this.pairingExpiresAt),
      pairedDashboardsCount:
          pairedDashboardsCount ?? this.pairedDashboardsCount,
      updateIntervalMs: updateIntervalMs ?? this.updateIntervalMs,
      lastUploadAt:
          clearLastUploadAt ? null : (lastUploadAt ?? this.lastUploadAt),
      lastFixAt: clearLastFixAt ? null : (lastFixAt ?? this.lastFixAt),
      lastAccuracyMeters:
          clearLastAccuracy ? null : (lastAccuracyMeters ?? this.lastAccuracyMeters),
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      hasPendingFix: hasPendingFix ?? this.hasPendingFix,
      pendingRecordedAt: clearPendingRecordedAt
          ? null
          : (pendingRecordedAt ?? this.pendingRecordedAt),
      hasLocationPermission:
          hasLocationPermission ?? this.hasLocationPermission,
      hasFineLocation: hasFineLocation ?? this.hasFineLocation,
      hasNotificationPermission:
          hasNotificationPermission ?? this.hasNotificationPermission,
      isLocationServiceEnabled:
          isLocationServiceEnabled ?? this.isLocationServiceEnabled,
      isNetworkConnected: isNetworkConnected ?? this.isNetworkConnected,
      networkType: networkType ?? this.networkType,
      busyAction: clearBusyAction ? null : (busyAction ?? this.busyAction),
    );
  }

  static DateTime? parseIsoDate(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return DateTime.tryParse(value.trim())?.toUtc();
  }
}
