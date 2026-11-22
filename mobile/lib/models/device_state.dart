/// Immutable state models for the LocaShare Family & Android client.
library;

enum BackendMode {
  php,
  supabase;

  static BackendMode fromWire(String? raw) =>
      raw?.trim().toLowerCase() == 'supabase'
          ? BackendMode.supabase
          : BackendMode.php;

  String toWire() => this == BackendMode.supabase ? 'supabase' : 'php';

  String get displayLabel =>
      this == BackendMode.supabase ? 'Supabase Cloud' : 'LocaShare PHP Server';
}

enum PresenceMode {
  atHome,
  atPlace,
  away,
  unknown;

  static PresenceMode fromWire(String? raw) {
    switch (raw?.trim().toLowerCase()) {
      case 'at_home':
        return PresenceMode.atHome;
      case 'at_place':
        return PresenceMode.atPlace;
      case 'away':
        return PresenceMode.away;
      default:
        return PresenceMode.unknown;
    }
  }

  String toWire() {
    switch (this) {
      case PresenceMode.atHome:
        return 'at_home';
      case PresenceMode.atPlace:
        return 'at_place';
      case PresenceMode.away:
        return 'away';
      case PresenceMode.unknown:
        return 'unknown';
    }
  }

  String displayLabel([String? placeName]) {
    switch (this) {
      case PresenceMode.atHome:
        return 'At Home';
      case PresenceMode.atPlace:
        return (placeName != null && placeName.isNotEmpty)
            ? 'At $placeName'
            : 'At Saved Place';
      case PresenceMode.away:
        return 'Out of House · Live';
      case PresenceMode.unknown:
        return 'Status Pending';
    }
  }
}

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
    this.backendMode = BackendMode.php,
    this.serverUrl = 'http://10.0.2.2:8080',
    this.supabaseUrl = '',
    this.supabaseAnonKey = '',
    this.deviceId = '',
    this.deviceToken = '',
    this.deviceName = 'Android Phone',
    this.statusState = PhoneStatusState.unregistered,
    this.isSharing = false,
    this.smartHomeMode = true,
    this.presenceMode = PresenceMode.unknown,
    this.currentPlaceId,
    this.currentPlaceName,
    this.homePrivacyMasked = false,
    this.lastLatitude,
    this.lastLongitude,
    this.circleId = '',
    this.circleName = '',
    this.memberName = '',
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

  final BackendMode backendMode;
  final String serverUrl;
  final String supabaseUrl;
  final String supabaseAnonKey;
  final String deviceId;
  final String deviceToken;
  final String deviceName;
  final PhoneStatusState statusState;
  final bool isSharing;
  final bool smartHomeMode;
  final PresenceMode presenceMode;
  final String? currentPlaceId;
  final String? currentPlaceName;
  final bool homePrivacyMasked;
  final double? lastLatitude;
  final double? lastLongitude;
  final String circleId;
  final String circleName;
  final String memberName;
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
  bool get isSupabaseMode => backendMode == BackendMode.supabase;

  bool get hasValidSupabaseConfig =>
      supabaseUrl.trim().startsWith('https://') &&
      supabaseAnonKey.trim().length >= 16;

  bool get isHttpsUrl {
    final target = isSupabaseMode ? supabaseUrl.trim() : serverUrl.trim();
    final uri = Uri.tryParse(target);
    return uri != null && uri.scheme.toLowerCase() == 'https';
  }

  bool get isLocalDevUrl {
    if (isSupabaseMode) return false;
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
    BackendMode? backendMode,
    String? serverUrl,
    String? supabaseUrl,
    String? supabaseAnonKey,
    String? deviceId,
    String? deviceToken,
    String? deviceName,
    PhoneStatusState? statusState,
    bool? isSharing,
    bool? smartHomeMode,
    PresenceMode? presenceMode,
    String? currentPlaceId,
    bool clearCurrentPlaceId = false,
    String? currentPlaceName,
    bool clearCurrentPlaceName = false,
    bool? homePrivacyMasked,
    double? lastLatitude,
    double? lastLongitude,
    bool clearLastCoords = false,
    String? circleId,
    String? circleName,
    String? memberName,
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
      backendMode: backendMode ?? this.backendMode,
      serverUrl: serverUrl ?? this.serverUrl,
      supabaseUrl: supabaseUrl ?? this.supabaseUrl,
      supabaseAnonKey: supabaseAnonKey ?? this.supabaseAnonKey,
      deviceId: deviceId ?? this.deviceId,
      deviceToken: deviceToken ?? this.deviceToken,
      deviceName: deviceName ?? this.deviceName,
      statusState: statusState ?? this.statusState,
      isSharing: isSharing ?? this.isSharing,
      smartHomeMode: smartHomeMode ?? this.smartHomeMode,
      presenceMode: presenceMode ?? this.presenceMode,
      currentPlaceId: clearCurrentPlaceId
          ? null
          : (currentPlaceId ?? this.currentPlaceId),
      currentPlaceName: clearCurrentPlaceName
          ? null
          : (currentPlaceName ?? this.currentPlaceName),
      homePrivacyMasked: homePrivacyMasked ?? this.homePrivacyMasked,
      lastLatitude:
          clearLastCoords ? null : (lastLatitude ?? this.lastLatitude),
      lastLongitude:
          clearLastCoords ? null : (lastLongitude ?? this.lastLongitude),
      circleId: circleId ?? this.circleId,
      circleName: circleName ?? this.circleName,
      memberName: memberName ?? this.memberName,
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
