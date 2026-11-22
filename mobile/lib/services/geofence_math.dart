import 'dart:math' as math;
import 'dart:ui';

/// Web Mercator (EPSG:3857) projection & Haversine geofence helpers.
class GeofenceMath {
  static const double tileSize = 256.0;
  static const double earthRadiusMeters = 6378137.0;
  static const double minZoom = 2.0;
  static const double maxZoom = 18.0;

  static double clampLat(double lat) => lat.clamp(-85.05112878, 85.05112878);

  static Offset latLngToWorldPx(double lat, double lng, double zoom) {
    final scale = tileSize * math.pow(2.0, zoom);
    final clamped = clampLat(lat);
    final x = ((lng + 180.0) / 360.0) * scale;
    final sinLat = math.sin(clamped * math.pi / 180.0);
    final y = (0.5 - math.log((1.0 + sinLat) / (1.0 - sinLat)) / (4.0 * math.pi)) * scale;
    return Offset(x, y);
  }

  static ({double lat, double lng}) worldPxToLatLng(double x, double y, double zoom) {
    final scale = tileSize * math.pow(2.0, zoom);
    final lngRaw = (x / scale) * 360.0 - 180.0;
    final n = math.pi - (2.0 * math.pi * y) / scale;
    final latRad = math.atan(0.5 * (math.exp(n) - math.exp(-n)));
    final lat = clampLat(latRad * 180.0 / math.pi);
    final lng = ((((lngRaw + 180.0) % 360.0) + 360.0) % 360.0) - 180.0;
    return (lat: lat, lng: lng);
  }

  static double metersPerPixel(double lat, double zoom) {
    final clamped = clampLat(lat);
    return (math.cos(clamped * math.pi / 180.0) * 2.0 * math.pi * earthRadiusMeters) /
        (tileSize * math.pow(2.0, zoom));
  }

  static double haversineMeters(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * math.pi / 180.0;
    final dLng = (lng2 - lng1) * math.pi / 180.0;
    final a = math.pow(math.sin(dLat / 2.0), 2) +
        math.cos(lat1 * math.pi / 180.0) *
            math.cos(lat2 * math.pi / 180.0) *
            math.pow(math.sin(dLng / 2.0), 2);
    return 2.0 * r * math.atan2(math.sqrt(a), math.sqrt(math.max(0.0, 1.0 - a)));
  }

  static String formatRelativeTime(DateTime? dt) {
    if (dt == null) return 'Never';
    final diff = DateTime.now().toUtc().difference(dt.toUtc());
    if (diff.inSeconds < 10) return 'Just now';
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
