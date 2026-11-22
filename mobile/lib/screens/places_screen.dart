import 'package:flutter/material.dart';

import '../models/family_models.dart';
import '../services/geofence_math.dart';
import '../services/location_controller.dart';
import '../widgets/family_map_canvas.dart';

class PlacesScreen extends StatefulWidget {
  const PlacesScreen({
    super.key,
    required this.controller,
    this.enableNetworkTiles = true,
  });

  final LocationController controller;
  final bool enableNetworkTiles;

  @override
  State<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends State<PlacesScreen> {
  Future<void> _openPlaceEditor({
    SavedPlace? existing,
    PlaceCategory initialCategory = PlaceCategory.home,
  }) async {
    final nameCtrl = TextEditingController(
      text: existing?.name ??
          switch (initialCategory) {
            PlaceCategory.home => 'Home',
            PlaceCategory.school => 'School',
            PlaceCategory.work => 'Work',
            PlaceCategory.custom => '',
          },
    );

    final fallbackCoords = await widget.controller.getCurrentCoordinates();
    if (!mounted) return;

    final latCtrl = TextEditingController(
      text: existing != null
          ? existing.latitude.toStringAsFixed(6)
          : (fallbackCoords?.lat.toStringAsFixed(6) ?? ''),
    );
    final lngCtrl = TextEditingController(
      text: existing != null
          ? existing.longitude.toStringAsFixed(6)
          : (fallbackCoords?.lng.toStringAsFixed(6) ?? ''),
    );

    var category = existing?.category ?? initialCategory;
    var radius = (existing?.radiusMeters ?? 150).toDouble().clamp(50.0, 1000.0);
    var notifyEnter = existing?.notifyOnEnter ?? true;
    var notifyExit = existing?.notifyOnExit ?? true;
    String? localError;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'Add Saved Place' : 'Edit ${existing.name}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<PlaceCategory>(
                  isExpanded: true,
                  initialValue: category,
                  decoration: const InputDecoration(
                    labelText: 'Place Type',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: PlaceCategory.home,
                      child: Text('Home (At-Home Privacy & Battery Saver)'),
                    ),
                    DropdownMenuItem(value: PlaceCategory.school, child: Text('School')),
                    DropdownMenuItem(value: PlaceCategory.work, child: Text('Work')),
                    DropdownMenuItem(value: PlaceCategory.custom, child: Text('Custom Place')),
                  ],
                  onChanged: (val) {
                    if (val == null) return;
                    setDialogState(() {
                      category = val;
                      if (existing == null &&
                          (nameCtrl.text.isEmpty ||
                              ['Home', 'School', 'Work'].contains(nameCtrl.text))) {
                        nameCtrl.text = val == PlaceCategory.custom ? '' : val.displayLabel;
                      }
                    });
                  },
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: nameCtrl,
                  maxLength: 64,
                  decoration: const InputDecoration(
                    labelText: 'Place Name',
                    hintText: 'Our House / Lincoln High / Office',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: latCtrl,
                        keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'Latitude',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: lngCtrl,
                        keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'Longitude',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        final coords = await widget.controller.getCurrentCoordinates();
                        if (coords != null) {
                          setDialogState(() {
                            latCtrl.text = coords.lat.toStringAsFixed(6);
                            lngCtrl.text = coords.lng.toStringAsFixed(6);
                            localError = null;
                          });
                        } else {
                          setDialogState(() {
                            localError = 'Grant location permission or start sharing first to read GPS.';
                          });
                        }
                      },
                      icon: const Icon(Icons.my_location, size: 16),
                      label: const Text('Use My GPS'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final startLat = double.tryParse(latCtrl.text.trim()) ??
                            fallbackCoords?.lat ??
                            14.5547;
                        final startLng = double.tryParse(lngCtrl.text.trim()) ??
                            fallbackCoords?.lng ??
                            121.0244;
                        final picked = await showDialog<({double lat, double lng})>(
                          context: ctx,
                          builder: (mapCtx) => Dialog(
                            child: SizedBox(
                              height: 380,
                              child: Column(
                                children: [
                                  AppBar(
                                    automaticallyImplyLeading: false,
                                    title: const Text('Tap Map to Pick Location', style: TextStyle(fontSize: 15)),
                                    actions: [
                                      IconButton(
                                        onPressed: () => Navigator.of(mapCtx).pop(),
                                        icon: const Icon(Icons.close),
                                      ),
                                    ],
                                  ),
                                  Expanded(
                                    child: FamilyMapCanvas(
                                      members: widget.controller.family.members,
                                      places: widget.controller.family.places,
                                      pickMode: true,
                                      initialLat: startLat,
                                      initialLng: startLng,
                                      enableNetworkTiles: widget.enableNetworkTiles,
                                      onPickCoordinate: (lat, lng) {
                                        Navigator.of(mapCtx).pop((lat: lat, lng: lng));
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                        if (picked != null) {
                          setDialogState(() {
                            latCtrl.text = picked.lat.toStringAsFixed(6);
                            lngCtrl.text = picked.lng.toStringAsFixed(6);
                            localError = null;
                          });
                        }
                      },
                      icon: const Icon(Icons.map_outlined, size: 16),
                      label: const Text('Pick on Map'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'Geofence Radius: ${radius.round()} meters',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                Slider(
                  value: radius,
                  min: 50,
                  max: 1000,
                  divisions: 19,
                  label: '${radius.round()}m',
                  onChanged: (v) => setDialogState(() => radius = v),
                ),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Alert when arriving'),
                  value: notifyEnter,
                  onChanged: (v) => setDialogState(() => notifyEnter = v),
                ),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Alert when leaving'),
                  value: notifyExit,
                  onChanged: (v) => setDialogState(() => notifyExit = v),
                ),
                if (localError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      localError!,
                      style: const TextStyle(color: Color(0xFFB91C1C), fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final lat = double.tryParse(latCtrl.text.trim());
                final lng = double.tryParse(lngCtrl.text.trim());
                if (lat == null || lng == null || lat < -90 || lat > 90 || lng < -180 || lng > 180) {
                  setDialogState(() => localError = 'Enter valid latitude (-90..90) and longitude (-180..180).');
                  return;
                }
                if (nameCtrl.text.trim().isEmpty) {
                  setDialogState(() => localError = 'Enter a place name.');
                  return;
                }
                Navigator.of(ctx).pop(true);
              },
              child: const Text('Save Place'),
            ),
          ],
        ),
      ),
    );

    if (saved == true && mounted) {
      await widget.controller.upsertSavedPlace(
        placeId: existing?.placeId,
        name: nameCtrl.text.trim(),
        category: category,
        latitude: double.parse(latCtrl.text.trim()),
        longitude: double.parse(lngCtrl.text.trim()),
        radiusMeters: radius.round(),
        notifyOnEnter: notifyEnter,
        notifyOnExit: notifyExit,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final family = widget.controller.family;
        final circle = family.circle;
        final home = family.homePlace;
        final places = family.places;
        final events = family.events;

        return Scaffold(
          backgroundColor: const Color(0xFFF1F5F9),
          appBar: AppBar(
            backgroundColor: const Color(0xFF0F172A),
            foregroundColor: Colors.white,
            title: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Places & Alerts', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                Text(
                  'Home geofence & School/Work arrival notifications',
                  style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                ),
              ],
            ),
            actions: [
              if (circle != null)
                IconButton(
                  tooltip: 'Add Saved Place',
                  onPressed: () => _openPlaceEditor(initialCategory: home == null ? PlaceCategory.home : PlaceCategory.school),
                  icon: const Icon(Icons.add_location_alt_outlined),
                ),
            ],
          ),
          body: circle == null
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Create or join a Family Circle in the "Circle & Device" tab first to set your Home geofence and receive arrival/departure alerts.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: Color(0xFF475569)),
                    ),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildHomeHeroCard(home),
                      const SizedBox(height: 14),
                      _buildSavedPlacesCard(places),
                      const SizedBox(height: 14),
                      _buildEventsTimelineCard(events),
                    ],
                  ),
                ),
        );
      },
    );
  }

  Widget _buildHomeHeroCard(SavedPlace? home) {
    return Card(
      elevation: 0,
      color: home == null ? const Color(0xFFFEF3C7) : const Color(0xFFECFDF5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: home == null ? const Color(0xFFFCD34D) : const Color(0xFF6EE7B7),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.home_rounded,
                  color: home == null ? const Color(0xFFB45309) : const Color(0xFF047857),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    home == null ? 'Set Our House (Home Geofence)' : '${home.name} (${home.radiusMeters}m zone)',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              home == null
                  ? 'Set your house boundary so LocaShare shows "At Home" inside (saving battery & privacy) and automatically turns on live GPS tracking when family members leave.'
                  : 'Smart Home tracking active: family phones inside ${home.radiusMeters}m show "At Home" and immediately switch to live GPS + send alerts when leaving.',
              style: const TextStyle(fontSize: 13, color: Color(0xFF334155)),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => _openPlaceEditor(existing: home, initialCategory: PlaceCategory.home),
              icon: Icon(home == null ? Icons.add_home : Icons.edit_location_alt),
              label: Text(home == null ? 'Set Home Location' : 'Update Home Boundary'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSavedPlacesCard(List<SavedPlace> places) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Saved Places', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _openPlaceEditor(initialCategory: PlaceCategory.school),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add Place'),
                ),
              ],
            ),
            if (places.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No places saved yet. Add Home, School, or Work to receive arrive/leave notifications.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                ),
              )
            else
              ...places.map((pl) {
                final icon = switch (pl.category) {
                  PlaceCategory.home => Icons.home_rounded,
                  PlaceCategory.school => Icons.school_rounded,
                  PlaceCategory.work => Icons.work_rounded,
                  PlaceCategory.custom => Icons.place_rounded,
                };
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xFFF1F5F9),
                    child: Icon(icon, color: const Color(0xFF0F766E), size: 20),
                  ),
                  title: Text(pl.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    '${pl.category.displayLabel} · ${pl.radiusMeters}m · '
                    '${pl.notifyOnEnter ? "Arrive " : ""}${pl.notifyOnExit ? "Leave" : ""}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Edit place',
                        icon: const Icon(Icons.edit_outlined, size: 19),
                        onPressed: () => _openPlaceEditor(existing: pl),
                      ),
                      IconButton(
                        tooltip: 'Delete place',
                        icon: const Icon(Icons.delete_outline, size: 19, color: Color(0xFFB91C1C)),
                        onPressed: () => widget.controller.deleteSavedPlace(pl.placeId),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildEventsTimelineCard(List<PlaceEvent> events) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Recent Place Activity', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const Spacer(),
                IconButton(
                  tooltip: 'Refresh alerts',
                  onPressed: () => widget.controller.refreshFamilySnapshot(quiet: false),
                  icon: const Icon(Icons.refresh, size: 19),
                ),
              ],
            ),
            if (events.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No arrive/leave events yet. Alerts appear here when someone leaves Home or arrives at School or Work.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                ),
              )
            else
              ...events.take(20).map((ev) {
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor: ev.isExit ? const Color(0xFFFEF3C7) : const Color(0xFFDCFCE7),
                    child: Icon(
                      ev.isExit ? Icons.logout_rounded : Icons.login_rounded,
                      size: 17,
                      color: ev.isExit ? const Color(0xFFB45309) : const Color(0xFF15803D),
                    ),
                  ),
                  title: Text(ev.summaryText, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    GeofenceMath.formatRelativeTime(ev.occurredAt),
                    style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
