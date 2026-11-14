import 'package:flutter/material.dart';

import '../models/device_state.dart';

class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.statusState,
  });

  final PhoneStatusState statusState;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, icon) = switch (statusState) {
      PhoneStatusState.sharing => (
          const Color(0xFFDCFCE7),
          const Color(0xFF166534),
          Icons.my_location,
        ),
      PhoneStatusState.waitingForPairing => (
          const Color(0xFFDBEAFE),
          const Color(0xFF1D4ED8),
          Icons.qr_code_2,
        ),
      PhoneStatusState.registered => (
          const Color(0xFFE0F2FE),
          const Color(0xFF0369A1),
          Icons.verified_user_outlined,
        ),
      PhoneStatusState.paused => (
          const Color(0xFFF1F5F9),
          const Color(0xFF334155),
          Icons.pause_circle_outline,
        ),
      PhoneStatusState.noGpsFix => (
          const Color(0xFFFEF3C7),
          const Color(0xFF92400E),
          Icons.gps_not_fixed,
        ),
      PhoneStatusState.offline => (
          const Color(0xFFFFEDD5),
          const Color(0xFF9A3412),
          Icons.wifi_off,
        ),
      PhoneStatusState.permissionMissing => (
          const Color(0xFFFEE2E2),
          const Color(0xFF991B1B),
          Icons.location_disabled,
        ),
      PhoneStatusState.unregistered => (
          const Color(0xFFF1F5F9),
          const Color(0xFF475569),
          Icons.phonelink_erase,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 6),
          Text(
            statusState.displayLabel,
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class InfoMetricTile extends StatelessWidget {
  const InfoMetricTile({
    super.key,
    required this.label,
    required this.value,
    this.highlight = false,
  });

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: highlight ? const Color(0xFFFFF7ED) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: highlight ? const Color(0xFFFDBA74) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xFF0F172A),
            ),
          ),
        ],
      ),
    );
  }
}
