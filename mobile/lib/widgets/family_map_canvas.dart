import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/device_state.dart';
import '../models/family_models.dart';
import '../services/geofence_math.dart';

enum MapTileStyle {
  esriStreet('Esri Street', 'https://services.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}'),
  esriSatellite('Satellite', 'https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'),
  osm('OSM', 'https://tile.openstreetmap.org/{z}/{x}/{y}.png'),
  localGrid('Privacy Grid', '');

  const MapTileStyle(this.label, this.urlTemplate);
  final String label;
  final String urlTemplate;
}

class FamilyMapCanvas extends StatefulWidget {
  const FamilyMapCanvas({
    super.key,
    required this.members,
    required this.places,
    this.selectedMemberDeviceId,
    this.onSelectMember,
    this.pickMode = false,
    this.onPickCoordinate,
    this.initialLat,
    this.initialLng,
    this.enableNetworkTiles = true,
  });

  final List<FamilyMember> members;
  final List<SavedPlace> places;
  final String? selectedMemberDeviceId;
  final ValueChanged<String>? onSelectMember;
  final bool pickMode;
  final void Function(double lat, double lng)? onPickCoordinate;
  final double? initialLat;
  final double? initialLng;
  final bool enableNetworkTiles;

  @override
  State<FamilyMapCanvas> createState() => FamilyMapCanvasState();
}

class FamilyMapCanvasState extends State<FamilyMapCanvas> {
  double _centerLat = 14.5547;
  double _centerLng = 121.0244;
  double _zoom = 15.0;
  MapTileStyle _tileStyle = MapTileStyle.esriStreet;
  bool _hasAutoFramed = false;
  Size _viewportSize = const Size(360, 420);

  Offset? _panLastFocal;
  double _scaleStartZoom = 15.0;

  @override
  void initState() {
    super.initState();
    if (widget.initialLat != null && widget.initialLng != null) {
      _centerLat = widget.initialLat!;
      _centerLng = widget.initialLng!;
      _hasAutoFramed = true;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) fitAll();
      });
    }
  }

  @override
  void didUpdateWidget(covariant FamilyMapCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_hasAutoFramed &&
        (widget.members.any((m) => m.hasLocation) || widget.places.isNotEmpty)) {
      fitAll();
    }
  }

  void centerOn(double lat, double lng, {double? zoom}) {
    setState(() {
      _centerLat = GeofenceMath.clampLat(lat);
      _centerLng = lng;
      if (zoom != null) {
        _zoom = zoom.clamp(GeofenceMath.minZoom, GeofenceMath.maxZoom);
      }
      _hasAutoFramed = true;
    });
  }

  void fitAll() {
    final pts = <({double lat, double lng})>[];
    for (final m in widget.members) {
      if (m.hasLocation && m.latitude != null && m.longitude != null) {
        pts.add((lat: m.latitude!, lng: m.longitude!));
      }
    }
    for (final p in widget.places) {
      pts.add((lat: p.latitude, lng: p.longitude));
    }
    if (pts.isEmpty) return;

    _hasAutoFramed = true;
    if (pts.length == 1) {
      setState(() {
        _centerLat = pts.first.lat;
        _centerLng = pts.first.lng;
        _zoom = 15.0;
      });
      return;
    }

    var minLat = 90.0;
    var maxLat = -90.0;
    var minLng = 180.0;
    var maxLng = -180.0;
    for (final pt in pts) {
      if (pt.lat < minLat) minLat = pt.lat;
      if (pt.lat > maxLat) maxLat = pt.lat;
      if (pt.lng < minLng) minLng = pt.lng;
      if (pt.lng > maxLng) maxLng = pt.lng;
    }

    var bestZoom = 15.0;
    for (var z = 16; z >= 3; z--) {
      final p1 = GeofenceMath.latLngToWorldPx(maxLat, minLng, z.toDouble());
      final p2 = GeofenceMath.latLngToWorldPx(minLat, maxLng, z.toDouble());
      if ((p2.dx - p1.dx).abs() < _viewportSize.width * 0.68 &&
          (p2.dy - p1.dy).abs() < _viewportSize.height * 0.68) {
        bestZoom = z.toDouble();
        break;
      }
    }

    setState(() {
      _centerLat = (minLat + maxLat) / 2.0;
      _centerLng = (minLng + maxLng) / 2.0;
      _zoom = bestZoom;
    });
  }

  Color _parseColor(String hex, {Color fallback = const Color(0xFF0EA5E9)}) {
    final clean = hex.replaceAll('#', '').trim();
    if (clean.length == 6) {
      final val = int.tryParse('FF$clean', radix: 16);
      if (val != null) return Color(val);
    }
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth > 0 ? constraints.maxWidth : 360.0;
        final h = constraints.maxHeight > 0 ? constraints.maxHeight : 420.0;
        _viewportSize = Size(w, h);

        final intZ = _zoom.floor().clamp(2, 18);
        final centerWorld = GeofenceMath.latLngToWorldPx(_centerLat, _centerLng, intZ.toDouble());
        final topLeftX = centerWorld.dx - w / 2.0;
        final topLeftY = centerWorld.dy - h / 2.0;

        return ClipRect(
          child: Container(
            color: const Color(0xFF0B1325),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: widget.pickMode && widget.onPickCoordinate != null
                  ? (details) {
                      final wx = topLeftX + details.localPosition.dx;
                      final wy = topLeftY + details.localPosition.dy;
                      final picked = GeofenceMath.worldPxToLatLng(wx, wy, intZ.toDouble());
                      widget.onPickCoordinate!(picked.lat, picked.lng);
                    }
                  : null,
              onScaleStart: (details) {
                _panLastFocal = details.localFocalPoint;
                _scaleStartZoom = _zoom;
              },
              onScaleUpdate: (details) {
                final prev = _panLastFocal ?? details.localFocalPoint;
                final delta = details.localFocalPoint - prev;
                _panLastFocal = details.localFocalPoint;

                final nextZoom = details.scale != 1.0
                    ? (_scaleStartZoom + math.log(details.scale) / math.ln2)
                        .clamp(GeofenceMath.minZoom, GeofenceMath.maxZoom)
                    : _zoom;

                final curWorld = GeofenceMath.latLngToWorldPx(_centerLat, _centerLng, nextZoom);
                final nextCenter = GeofenceMath.worldPxToLatLng(
                  curWorld.dx - delta.dx,
                  curWorld.dy - delta.dy,
                  nextZoom,
                );
                setState(() {
                  _zoom = nextZoom;
                  _centerLat = nextCenter.lat;
                  _centerLng = nextCenter.lng;
                });
              },
              child: Stack(
                children: [
                  if (widget.enableNetworkTiles && _tileStyle != MapTileStyle.localGrid)
                    ..._buildTileWidgets(w, h, intZ, topLeftX, topLeftY),
                  CustomPaint(
                    size: Size(w, h),
                    painter: _GeofenceGridPainter(
                      places: widget.places,
                      members: widget.members,
                      selectedDeviceId: widget.selectedMemberDeviceId,
                      zoom: intZ.toDouble(),
                      topLeftX: topLeftX,
                      topLeftY: topLeftY,
                      showGrid: _tileStyle == MapTileStyle.localGrid || !widget.enableNetworkTiles,
                    ),
                  ),
                  ..._buildPlaceBadges(w, h, intZ.toDouble(), topLeftX, topLeftY),
                  ..._buildMemberMarkers(w, h, intZ.toDouble(), topLeftX, topLeftY),
                  if (widget.pickMode)
                    Positioned(
                      top: 12,
                      left: 12,
                      right: 64,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xE60F172A),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF10B981)),
                        ),
                        child: const Text(
                          'Tap anywhere on the map to set this place center',
                          style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  Positioned(
                    top: 12,
                    right: 12,
                    child: Column(
                      children: [
                        _MapControlButton(
                          icon: Icons.add,
                          tooltip: 'Zoom in',
                          onTap: () => setState(() {
                            _zoom = (_zoom + 1).clamp(GeofenceMath.minZoom, GeofenceMath.maxZoom);
                          }),
                        ),
                        const SizedBox(height: 6),
                        _MapControlButton(
                          icon: Icons.remove,
                          tooltip: 'Zoom out',
                          onTap: () => setState(() {
                            _zoom = (_zoom - 1).clamp(GeofenceMath.minZoom, GeofenceMath.maxZoom);
                          }),
                        ),
                        const SizedBox(height: 6),
                        _MapControlButton(
                          icon: Icons.fit_screen,
                          tooltip: 'Fit family',
                          onTap: fitAll,
                        ),
                        const SizedBox(height: 6),
                        _MapControlButton(
                          icon: Icons.layers_outlined,
                          tooltip: 'Cycle map style',
                          onTap: () {
                            const values = MapTileStyle.values;
                            final next = values[(_tileStyle.index + 1) % values.length];
                            setState(() => _tileStyle = next);
                          },
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    bottom: 8,
                    left: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xCC0F172A),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '${_tileStyle.label} · z$intZ',
                        style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 10),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildTileWidgets(double w, double h, int z, double topLeftX, double topLeftY) {
    const ts = GeofenceMath.tileSize;
    final startX = (topLeftX / ts).floor();
    final endX = ((topLeftX + w) / ts).floor();
    final startY = (topLeftY / ts).floor();
    final endY = ((topLeftY + h) / ts).floor();
    final maxTile = math.pow(2, z).toInt();

    final tiles = <Widget>[];
    for (var tx = startX; tx <= endX; tx++) {
      for (var ty = startY; ty <= endY; ty++) {
        if (ty < 0 || ty >= maxTile) continue;
        final wrappedX = ((tx % maxTile) + maxTile) % maxTile;
        final url = _tileStyle.urlTemplate
            .replaceAll('{z}', '$z')
            .replaceAll('{x}', '$wrappedX')
            .replaceAll('{y}', '$ty');

        tiles.add(
          Positioned(
            left: tx * ts - topLeftX,
            top: ty * ts - topLeftY,
            width: ts + 0.5,
            height: ts + 0.5,
            child: Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        );
      }
    }
    return tiles;
  }

  List<Widget> _buildPlaceBadges(double w, double h, double z, double topLeftX, double topLeftY) {
    final badges = <Widget>[];
    for (final pl in widget.places) {
      final pt = GeofenceMath.latLngToWorldPx(pl.latitude, pl.longitude, z);
      final sx = pt.dx - topLeftX;
      final sy = pt.dy - topLeftY;
      if (sx < -60 || sx > w + 60 || sy < -60 || sy > h + 60) continue;

      final color = switch (pl.category) {
        PlaceCategory.home => const Color(0xFF10B981),
        PlaceCategory.school => const Color(0xFF8B5CF6),
        PlaceCategory.work => const Color(0xFFF59E0B),
        PlaceCategory.custom => const Color(0xFF0EA5E9),
      };
      final icon = switch (pl.category) {
        PlaceCategory.home => Icons.home_rounded,
        PlaceCategory.school => Icons.school_rounded,
        PlaceCategory.work => Icons.work_rounded,
        PlaceCategory.custom => Icons.place_rounded,
      };

      badges.add(
        Positioned(
          left: sx - 56,
          top: sy - 14,
          width: 112,
          child: IgnorePointer(
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xEB0F172A),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: color, width: 1.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 12, color: color),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        pl.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return badges;
  }

  List<Widget> _buildMemberMarkers(double w, double h, double z, double topLeftX, double topLeftY) {
    final pins = <Widget>[];
    for (final m in widget.members) {
      if (!m.hasLocation || m.latitude == null || m.longitude == null) continue;
      final pt = GeofenceMath.latLngToWorldPx(m.latitude!, m.longitude!, z);
      final sx = pt.dx - topLeftX;
      final sy = pt.dy - topLeftY;
      if (sx < -60 || sx > w + 60 || sy < -60 || sy > h + 60) continue;

      final isSelected = m.deviceId == widget.selectedMemberDeviceId;
      final avatarColor = _parseColor(m.avatarColorHex);
      final statusColor = !m.isOnline
          ? const Color(0xFF64748B)
          : (m.presenceMode == PresenceMode.atHome
              ? const Color(0xFF10B981)
              : const Color(0xFF0EA5E9));

      pins.add(
        Positioned(
          left: sx - 44,
          top: sy - 22,
          width: 88,
          child: GestureDetector(
            onTap: () {
              widget.onSelectMember?.call(m.deviceId);
              centerOn(m.latitude!, m.longitude!, zoom: math.max(_zoom, 15.0));
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: isSelected ? 38 : 32,
                  height: isSelected ? 38 : 32,
                  decoration: BoxDecoration(
                    color: avatarColor,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected ? Colors.amberAccent : Colors.white,
                      width: isSelected ? 3 : 2,
                    ),
                    boxShadow: const [
                      BoxShadow(color: Colors.black45, blurRadius: 6, offset: Offset(0, 2)),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    m.initials,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xEE0F172A),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: statusColor, width: 1),
                  ),
                  child: Text(
                    m.presenceMode == PresenceMode.atHome
                        ? '${m.displayLabel} · Home'
                        : m.displayLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return pins;
  }
}

class _MapControlButton extends StatelessWidget {
  const _MapControlButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xE61E293B),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(icon, color: Colors.white, size: 20),
          ),
        ),
      ),
    );
  }
}

class _GeofenceGridPainter extends CustomPainter {
  _GeofenceGridPainter({
    required this.places,
    required this.members,
    required this.selectedDeviceId,
    required this.zoom,
    required this.topLeftX,
    required this.topLeftY,
    required this.showGrid,
  });

  final List<SavedPlace> places;
  final List<FamilyMember> members;
  final String? selectedDeviceId;
  final double zoom;
  final double topLeftX;
  final double topLeftY;
  final bool showGrid;

  @override
  void paint(Canvas canvas, Size size) {
    if (showGrid) {
      final gridPaint = Paint()
        ..color = const Color(0x2238BDF8)
        ..strokeWidth = 1;
      for (double x = 0; x <= size.width; x += 48) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
      }
      for (double y = 0; y <= size.height; y += 48) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
      }
    }

    // Saved Places geofence radius rings
    for (final pl in places) {
      final pt = GeofenceMath.latLngToWorldPx(pl.latitude, pl.longitude, zoom);
      final cx = pt.dx - topLeftX;
      final cy = pt.dy - topLeftY;
      final mpp = GeofenceMath.metersPerPixel(pl.latitude, zoom);
      final maxDim = math.max(size.width, size.height);
      final radiusPx = (pl.radiusMeters / mpp).clamp(14.0, maxDim).toDouble();

      final baseColor = switch (pl.category) {
        PlaceCategory.home => const Color(0xFF10B981),
        PlaceCategory.school => const Color(0xFF8B5CF6),
        PlaceCategory.work => const Color(0xFFF59E0B),
        PlaceCategory.custom => const Color(0xFF0EA5E9),
      };

      canvas.drawCircle(
        Offset(cx, cy),
        radiusPx,
        Paint()..color = baseColor.withValues(alpha: 0.16),
      );
      canvas.drawCircle(
        Offset(cx, cy),
        radiusPx,
        Paint()
          ..color = baseColor.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = pl.isHome ? 2.4 : 1.8,
      );
    }

    // Member GPS accuracy rings
    for (final m in members) {
      if (!m.hasLocation || m.latitude == null || m.longitude == null) continue;
      final acc = m.accuracyMeters;
      if (acc == null || acc <= 0) continue;
      final pt = GeofenceMath.latLngToWorldPx(m.latitude!, m.longitude!, zoom);
      final cx = pt.dx - topLeftX;
      final cy = pt.dy - topLeftY;
      final mpp = GeofenceMath.metersPerPixel(m.latitude!, zoom);
      final radiusPx = (acc / mpp).clamp(10.0, size.width).toDouble();
      final isSel = m.deviceId == selectedDeviceId;

      canvas.drawCircle(
        Offset(cx, cy),
        radiusPx,
        Paint()
          ..color = (isSel ? const Color(0xFF38BDF8) : const Color(0xFF10B981))
              .withValues(alpha: 0.14),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GeofenceGridPainter oldDelegate) =>
      oldDelegate.places != places ||
      oldDelegate.members != members ||
      oldDelegate.selectedDeviceId != selectedDeviceId ||
      oldDelegate.zoom != zoom ||
      oldDelegate.topLeftX != topLeftX ||
      oldDelegate.topLeftY != topLeftY ||
      oldDelegate.showGrid != showGrid;
}
