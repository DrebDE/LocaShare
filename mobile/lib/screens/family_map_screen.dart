import 'package:flutter/material.dart';

import '../models/device_state.dart';
import '../models/family_models.dart';
import '../services/geofence_math.dart';
import '../services/location_controller.dart';
import '../widgets/family_map_canvas.dart';

class FamilyMapScreen extends StatefulWidget {
  const FamilyMapScreen({
    super.key,
    required this.controller,
    this.onNavigateToCircleSetup,
    this.onNavigateToPlaces,
    this.enableNetworkTiles = true,
  });

  final LocationController controller;
  final VoidCallback? onNavigateToCircleSetup;
  final VoidCallback? onNavigateToPlaces;
  final bool enableNetworkTiles;

  @override
  State<FamilyMapScreen> createState() => _FamilyMapScreenState();
}

class _FamilyMapScreenState extends State<FamilyMapScreen> {
  final GlobalKey<FamilyMapCanvasState> _mapKey = GlobalKey<FamilyMapCanvasState>();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final s = widget.controller.state;
        final family = widget.controller.family;
        final circle = family.circle;
        final members = family.members;
        final places = family.places;
        final home = family.homePlace;

        final awayCount = members.where((m) => m.presenceMode == PresenceMode.away || m.presenceMode == PresenceMode.atPlace).length;
        final atHomeCount = members.where((m) => m.presenceMode == PresenceMode.atHome).length;

        return Scaffold(
          backgroundColor: const Color(0xFFF1F5F9),
          appBar: AppBar(
            backgroundColor: const Color(0xFF0F172A),
            foregroundColor: Colors.white,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  circle?.name ?? 'Family Map',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
                Text(
                  circle == null
                      ? 'Create or join a Family Circle'
                      : '$awayCount away · $atHomeCount at home',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Refresh family locations',
                onPressed: () => widget.controller.refreshFamilySnapshot(quiet: false),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: Column(
            children: [
              if (circle == null)
                _buildJoinCircleCallout(s)
              else if (home == null)
                _buildSetHomeBanner(),
              Expanded(
                child: FamilyMapCanvas(
                  key: _mapKey,
                  members: members,
                  places: places,
                  selectedMemberDeviceId: widget.controller.selectedMemberDeviceId,
                  enableNetworkTiles: widget.enableNetworkTiles,
                  onSelectMember: (id) {
                    widget.controller.selectFamilyMember(id);
                  },
                ),
              ),
              if (members.isNotEmpty) _buildMembersDrawer(members, home),
            ],
          ),
        );
      },
    );
  }

  Widget _buildJoinCircleCallout(DeviceTrackerState s) {
    return Container(
      width: double.infinity,
      color: const Color(0xFFECFDF5),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.group_add, color: Color(0xFF0F766E)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              s.isRegistered
                  ? 'Create a Family Circle or enter a family invite code to see everyone on the map.'
                  : 'Register this device first in the Circle & Device tab to join your Family Circle.',
              style: const TextStyle(fontSize: 12, color: Color(0xFF134E4A), fontWeight: FontWeight.w500),
            ),
          ),
          TextButton(
            onPressed: widget.onNavigateToCircleSetup,
            child: const Text('Setup'),
          ),
        ],
      ),
    );
  }

  Widget _buildSetHomeBanner() {
    return Container(
      width: double.infinity,
      color: const Color(0xFFFEF3C7),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.home_outlined, color: Color(0xFFB45309)),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Set your Home location so LocaShare knows when family members are at home vs. out of the house.',
              style: TextStyle(fontSize: 12, color: Color(0xFF92400E), fontWeight: FontWeight.w500),
            ),
          ),
          TextButton(
            onPressed: widget.onNavigateToPlaces,
            child: const Text('Set Home'),
          ),
        ],
      ),
    );
  }

  Widget _buildMembersDrawer(List<FamilyMember> members, SavedPlace? home) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text(
                'Family Members',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF0F172A)),
              ),
              const Spacer(),
              if (home != null)
                Text(
                  'Home: ${home.name} (${home.radiusMeters}m)',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF047857), fontWeight: FontWeight.w600),
                ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 110,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: members.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final m = members[index];
                final isSelected = m.deviceId == widget.controller.selectedMemberDeviceId;
                final presenceBg = switch (m.presenceMode) {
                  PresenceMode.atHome => const Color(0xFFDCFCE7),
                  PresenceMode.atPlace => const Color(0xFFEDE9FE),
                  PresenceMode.away => const Color(0xFFE0F2FE),
                  PresenceMode.unknown => const Color(0xFFF1F5F9),
                };
                final presenceFg = switch (m.presenceMode) {
                  PresenceMode.atHome => const Color(0xFF166534),
                  PresenceMode.atPlace => const Color(0xFF5B21B6),
                  PresenceMode.away => const Color(0xFF075985),
                  PresenceMode.unknown => const Color(0xFF475569),
                };

                final subText = !m.isOnline
                    ? 'Offline · ${GeofenceMath.formatRelativeTime(m.lastHeartbeatAt)}'
                    : (m.hasLocation
                        ? 'Updated ${GeofenceMath.formatRelativeTime(m.locationRecordedAt)}'
                        : 'Waiting for GPS fix');

                return InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    widget.controller.selectFamilyMember(m.deviceId);
                    if (m.hasLocation && m.latitude != null && m.longitude != null) {
                      _mapKey.currentState?.centerOn(m.latitude!, m.longitude!, zoom: 16);
                    }
                  },
                  child: Container(
                    width: 196,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isSelected ? const Color(0xFFF0F9FF) : const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected ? const Color(0xFF0EA5E9) : const Color(0xFFE2E8F0),
                        width: isSelected ? 1.8 : 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 13,
                              backgroundColor: const Color(0xFF0F766E),
                              child: Text(
                                m.initials,
                                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                m.isSelf ? '${m.displayLabel} (You)' : m.displayLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                              ),
                            ),
                            if (m.battery != null)
                              Text(
                                '${m.battery}%',
                                style: const TextStyle(fontSize: 11, color: Color(0xFF475569), fontWeight: FontWeight.w600),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: presenceBg,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            m.presenceMode == PresenceMode.atHome && m.homePrivacyMasked
                                ? 'At Home · Battery Saver'
                                : m.presenceMode.displayLabel(m.currentPlaceName),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: presenceFg),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          subText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
