import 'device_state.dart';

enum PlaceCategory {
  home,
  school,
  work,
  custom;

  static PlaceCategory fromWire(String? raw) {
    switch (raw?.trim().toLowerCase()) {
      case 'home':
        return PlaceCategory.home;
      case 'school':
        return PlaceCategory.school;
      case 'work':
        return PlaceCategory.work;
      default:
        return PlaceCategory.custom;
    }
  }

  String toWire() => name;

  String get displayLabel {
    switch (this) {
      case PlaceCategory.home:
        return 'Home';
      case PlaceCategory.school:
        return 'School';
      case PlaceCategory.work:
        return 'Work';
      case PlaceCategory.custom:
        return 'Custom';
    }
  }
}

class SavedPlace {
  const SavedPlace({
    required this.placeId,
    required this.circleId,
    required this.name,
    required this.category,
    required this.latitude,
    required this.longitude,
    required this.radiusMeters,
    required this.isHome,
    required this.notifyOnEnter,
    required this.notifyOnExit,
  });

  final String placeId;
  final String circleId;
  final String name;
  final PlaceCategory category;
  final double latitude;
  final double longitude;
  final int radiusMeters;
  final bool isHome;
  final bool notifyOnEnter;
  final bool notifyOnExit;

  factory SavedPlace.fromJson(Map<String, dynamic> json) {
    final category = PlaceCategory.fromWire(json['category'] as String?);
    final isHome = json['is_home'] == true || category == PlaceCategory.home;
    return SavedPlace(
      placeId: (json['place_id'] as String?) ?? '',
      circleId: (json['circle_id'] as String?) ?? '',
      name: (json['name'] as String?) ?? 'Place',
      category: category,
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0.0,
      radiusMeters: ((json['radius_meters'] as num?)?.toInt() ?? 150).clamp(50, 5000),
      isHome: isHome,
      notifyOnEnter: json['notify_on_enter'] != false,
      notifyOnExit: json['notify_on_exit'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
        'place_id': placeId,
        'circle_id': circleId,
        'name': name,
        'category': category.toWire(),
        'latitude': latitude,
        'longitude': longitude,
        'radius_meters': radiusMeters,
        'is_home': isHome,
        'notify_on_enter': notifyOnEnter,
        'notify_on_exit': notifyOnExit,
      };
}

class FamilyCircle {
  const FamilyCircle({
    required this.circleId,
    required this.name,
    required this.inviteCode,
    required this.myRole,
    required this.myMemberName,
  });

  final String circleId;
  final String name;
  final String inviteCode;
  final String myRole;
  final String myMemberName;

  factory FamilyCircle.fromJson(Map<String, dynamic> json) {
    return FamilyCircle(
      circleId: (json['circle_id'] as String?) ?? '',
      name: (json['name'] as String?) ?? 'Our Family',
      inviteCode: (json['invite_code'] as String?) ?? '',
      myRole: (json['my_role'] as String?) ?? 'member',
      myMemberName: (json['my_member_name'] as String?) ?? '',
    );
  }
}

class FamilyMember {
  const FamilyMember({
    required this.deviceId,
    required this.deviceName,
    required this.memberName,
    required this.role,
    required this.avatarColorHex,
    required this.isSelf,
    required this.sharingEnabled,
    required this.statusState,
    required this.presenceMode,
    this.currentPlaceId,
    this.currentPlaceName,
    required this.homePrivacyMasked,
    required this.smartHomeMode,
    this.speedMps,
    required this.isOnline,
    this.battery,
    this.isCharging,
    required this.networkStatus,
    required this.hasLocation,
    required this.isLocationFresh,
    this.latitude,
    this.longitude,
    this.accuracyMeters,
    this.locationRecordedAt,
    this.lastHeartbeatAt,
  });

  final String deviceId;
  final String deviceName;
  final String memberName;
  final String role;
  final String avatarColorHex;
  final bool isSelf;
  final bool sharingEnabled;
  final PhoneStatusState statusState;
  final PresenceMode presenceMode;
  final String? currentPlaceId;
  final String? currentPlaceName;
  final bool homePrivacyMasked;
  final bool smartHomeMode;
  final double? speedMps;
  final bool isOnline;
  final int? battery;
  final bool? isCharging;
  final String networkStatus;
  final bool hasLocation;
  final bool isLocationFresh;
  final double? latitude;
  final double? longitude;
  final double? accuracyMeters;
  final DateTime? locationRecordedAt;
  final DateTime? lastHeartbeatAt;

  String get displayLabel => memberName.isNotEmpty ? memberName : deviceName;

  String get initials {
    final parts = displayLabel.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }

  factory FamilyMember.fromJson(Map<String, dynamic> json) {
    final loc = json['location'] as Map<String, dynamic>?;
    return FamilyMember(
      deviceId: (json['device_id'] as String?) ?? '',
      deviceName: (json['device_name'] as String?) ?? 'Android Phone',
      memberName: (json['member_name'] as String?) ?? '',
      role: (json['role'] as String?) ?? 'member',
      avatarColorHex: (json['avatar_color'] as String?) ?? '#0EA5E9',
      isSelf: json['is_self'] == true,
      sharingEnabled: json['sharing_enabled'] == true,
      statusState: PhoneStatusState.fromWire(json['status_state'] as String?),
      presenceMode: PresenceMode.fromWire(json['presence_mode'] as String?),
      currentPlaceId: json['current_place_id'] as String?,
      currentPlaceName: json['current_place_name'] as String?,
      homePrivacyMasked: json['home_privacy_masked'] == true,
      smartHomeMode: json['smart_home_mode'] != false,
      speedMps: (json['speed_mps'] as num?)?.toDouble(),
      isOnline: json['is_online'] == true,
      battery: (json['battery'] as num?)?.toInt(),
      isCharging: json['is_charging'] as bool?,
      networkStatus: (json['network_status'] as String?) ?? 'unknown',
      hasLocation: json['has_location'] == true && loc != null,
      isLocationFresh: json['is_location_fresh'] == true || (loc?['is_fresh'] == true),
      latitude: (loc?['latitude'] as num?)?.toDouble(),
      longitude: (loc?['longitude'] as num?)?.toDouble(),
      accuracyMeters: (loc?['accuracy'] as num?)?.toDouble(),
      locationRecordedAt: DeviceTrackerState.parseIsoDate(loc?['recorded_at']),
      lastHeartbeatAt: DeviceTrackerState.parseIsoDate(json['last_heartbeat_at']),
    );
  }
}

class PlaceEvent {
  const PlaceEvent({
    required this.eventId,
    required this.deviceId,
    required this.memberName,
    required this.placeId,
    required this.placeName,
    required this.placeCategory,
    required this.eventType,
    required this.occurredAt,
  });

  final String eventId;
  final String deviceId;
  final String memberName;
  final String placeId;
  final String placeName;
  final PlaceCategory placeCategory;
  final String eventType; // 'entered' | 'exited'
  final DateTime? occurredAt;

  bool get isExit => eventType == 'exited';

  String get summaryText {
    final verb = isExit ? 'left' : 'arrived at';
    return '$memberName $verb $placeName';
  }

  factory PlaceEvent.fromJson(Map<String, dynamic> json) {
    return PlaceEvent(
      eventId: (json['event_id'] as String?) ?? '',
      deviceId: (json['device_id'] as String?) ?? '',
      memberName: (json['member_name'] as String?) ?? 'Member',
      placeId: (json['place_id'] as String?) ?? '',
      placeName: (json['place_name'] as String?) ?? 'Place',
      placeCategory: PlaceCategory.fromWire(json['place_category'] as String?),
      eventType: (json['event_type'] as String?) ?? 'entered',
      occurredAt: DeviceTrackerState.parseIsoDate(json['occurred_at']),
    );
  }
}

class FamilySnapshot {
  const FamilySnapshot({
    this.circle,
    this.members = const [],
    this.places = const [],
    this.events = const [],
    this.serverTime,
  });

  final FamilyCircle? circle;
  final List<FamilyMember> members;
  final List<SavedPlace> places;
  final List<PlaceEvent> events;
  final DateTime? serverTime;

  SavedPlace? get homePlace {
    for (final p in places) {
      if (p.isHome) return p;
    }
    return null;
  }

  factory FamilySnapshot.fromJson(Map<String, dynamic> json) {
    final circleRaw = json['circle'] as Map<String, dynamic>?;
    final membersRaw = json['members'] as List<dynamic>? ?? const [];
    final placesRaw = json['places'] as List<dynamic>? ?? const [];
    final eventsRaw = json['events'] as List<dynamic>? ?? const [];

    return FamilySnapshot(
      circle: circleRaw != null ? FamilyCircle.fromJson(circleRaw) : null,
      members: membersRaw
          .whereType<Map<String, dynamic>>()
          .map(FamilyMember.fromJson)
          .toList(),
      places: placesRaw
          .whereType<Map<String, dynamic>>()
          .map(SavedPlace.fromJson)
          .toList(),
      events: eventsRaw
          .whereType<Map<String, dynamic>>()
          .map(PlaceEvent.fromJson)
          .toList(),
      serverTime: DeviceTrackerState.parseIsoDate(json['server_time']),
    );
  }
}
