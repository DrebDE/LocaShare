import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/device_state.dart';
import '../services/location_controller.dart';
import '../widgets/pairing_card.dart';
import '../widgets/permission_rationale_dialog.dart';
import '../widgets/status_chips.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.controller,
  });

  final LocationController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _deviceNameController = TextEditingController();

  @override
  void dispose() {
    _deviceNameController.dispose();
    super.dispose();
  }

  String _formatTime(DateTime? dt) {
    if (dt == null) return 'Never';
    final local = dt.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final ss = local.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }

  Future<void> _openBackendConfigDialog(DeviceTrackerState s) async {
    var mode = s.backendMode;
    final serverCtrl = TextEditingController(text: s.serverUrl);
    final supaUrlCtrl = TextEditingController(text: s.supabaseUrl);
    final supaKeyCtrl = TextEditingController(text: s.supabaseAnonKey);

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Configure Backend'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<BackendMode>(
                  segments: const [
                    ButtonSegment(
                      value: BackendMode.supabase,
                      label: Text('Supabase Cloud'),
                    ),
                    ButtonSegment(
                      value: BackendMode.php,
                      label: Text('PHP Server'),
                    ),
                  ],
                  selected: {mode},
                  onSelectionChanged: (next) {
                    setDialogState(() => mode = next.first);
                  },
                ),
                const SizedBox(height: 12),
                if (mode == BackendMode.supabase) ...[
                  TextField(
                    controller: supaUrlCtrl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Supabase Project URL',
                      hintText: 'https://xyzcompany.supabase.co',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: supaKeyCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Supabase Anon Public Key',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Free cloud backend: works immediately over mobile data with Realtime sync & Edge Function alerts.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF475569)),
                  ),
                ] else ...[
                  TextField(
                    controller: serverCtrl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Server Base URL',
                      hintText: 'https://track.example.com',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Use a public HTTPS URL to track this phone over mobile data or outside your local Wi-Fi network.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF475569)),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (saved == true && mounted) {
      await widget.controller.saveBackendConfig(
        mode: mode,
        serverUrl: serverCtrl.text.trim(),
        supabaseUrl: supaUrlCtrl.text.trim(),
        supabaseAnonKey: supaKeyCtrl.text.trim(),
      );
    }
  }

  Future<void> _openCreateCircleDialog(DeviceTrackerState s) async {
    final circleCtrl = TextEditingController(text: 'Our Family');
    final memberCtrl = TextEditingController(text: s.deviceName);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create Family Circle'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: circleCtrl,
              maxLength: 64,
              decoration: const InputDecoration(
                labelText: 'Family Circle Name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: memberCtrl,
              maxLength: 64,
              decoration: const InputDecoration(
                labelText: 'Your Name in Circle',
                hintText: 'Mom / Dad / Alex',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Create Circle'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await widget.controller.createFamilyCircle(
        circleName: circleCtrl.text.trim(),
        memberName: memberCtrl.text.trim(),
      );
    }
  }

  Future<void> _openJoinCircleDialog(DeviceTrackerState s) async {
    final codeCtrl = TextEditingController();
    final memberCtrl = TextEditingController(text: s.deviceName);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Join Family Circle'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: codeCtrl,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Invite Code',
                hintText: 'FAM-XXXX-XXXX',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: memberCtrl,
              maxLength: 64,
              decoration: const InputDecoration(
                labelText: 'Your Name in Circle',
                hintText: 'Alex / Mom',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Join'),
          ),
        ],
      ),
    );
    if (ok == true && mounted && codeCtrl.text.trim().isNotEmpty) {
      await widget.controller.joinFamilyCircle(
        inviteCode: codeCtrl.text.trim(),
        memberName: memberCtrl.text.trim(),
      );
    }
  }

  Future<void> _handleStartSharing(DeviceTrackerState s) async {
    if (!s.hasLocationPermission) {
      final proceed = await showPermissionRationaleDialog(context);
      if (!proceed || !mounted) return;
      final granted = await widget.controller.requestPermissionsFromOs();
      if (!granted || !mounted) return;
    }
    await widget.controller.startSharing();
  }

  Future<void> _confirmAndRevokePairings() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke Dashboard Pairings?'),
        content: const Text(
          'This immediately disconnects all laptop browsers from this phone, stops sharing, and clears your stored coordinates from the server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Revoke Access'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.controller.revokeDashboardPairings();
    }
  }

  Future<void> _confirmAndUnregister() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unregister This Device?'),
        content: const Text(
          'This stops location sharing, revokes all paired dashboards, deletes your stored coordinates, and invalidates this device\'s API token.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Unregister Device'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.controller.unregisterDevice();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final s = widget.controller.state;
        if (_deviceNameController.text.isEmpty && s.deviceName.isNotEmpty) {
          _deviceNameController.text = s.deviceName;
        }

        return Scaffold(
          backgroundColor: const Color(0xFFF1F5F9),
          appBar: AppBar(
            backgroundColor: const Color(0xFF0F172A),
            foregroundColor: Colors.white,
            title: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'LocaShare',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                Text(
                  'Family circle & consent-first tracking',
                  style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Backend Settings',
                onPressed: () => _openBackendConfigDialog(s),
                icon: const Icon(Icons.dns_outlined),
              ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildServerCard(s),
                const SizedBox(height: 12),
                _buildStatusSummaryCard(s),
                if (s.lastError != null && s.lastError!.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _buildBanner(
                    color: const Color(0xFFFEE2E2),
                    borderColor: const Color(0xFFFCA5A5),
                    textColor: const Color(0xFF991B1B),
                    icon: Icons.error_outline,
                    text: s.lastError!,
                  ),
                ] else if (widget.controller.statusMessage != null) ...[
                  const SizedBox(height: 10),
                  _buildBanner(
                    color: const Color(0xFFECFEFF),
                    borderColor: const Color(0xFFA5F3FC),
                    textColor: const Color(0xFF155E75),
                    icon: Icons.info_outline,
                    text: widget.controller.statusMessage!,
                  ),
                ],
                const SizedBox(height: 12),
                if (!s.isRegistered)
                  _buildUnregisteredCard(s)
                else ...[
                  _buildFamilyCircleCard(s),
                  const SizedBox(height: 12),
                  _buildSharingControlsCard(s),
                  if (!s.isSupabaseMode) ...[
                    const SizedBox(height: 12),
                    PairingCodeCard(
                      pairingCode: s.pairingCode,
                      qrPayload: s.pairingQrPayload,
                      secondsRemaining: s.pairingSecondsRemaining,
                      pairedDashboardsCount: s.pairedDashboardsCount,
                      isBusy: s.isBusy,
                      onGenerateNewCode: widget.controller.refreshPairingCode,
                      onRefreshStatus: () =>
                          widget.controller.refreshServerStatus(quiet: false),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _buildPrivacyActionsCard(s),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildServerCard(DeviceTrackerState s) {
    final isNonHttpsRemote = !s.isHttpsUrl && !s.isLocalDevUrl && !s.isSupabaseMode;
    final displayUrl = s.isSupabaseMode
        ? (s.supabaseUrl.isNotEmpty ? s.supabaseUrl : 'Supabase Cloud (Not Configured)')
        : s.serverUrl;

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  s.isSupabaseMode
                      ? Icons.cloud_done_outlined
                      : (s.isHttpsUrl ? Icons.lock : Icons.lock_open),
                  size: 16,
                  color: s.isHttpsUrl
                      ? const Color(0xFF16A34A)
                      : const Color(0xFFD97706),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.backendMode.displayLabel,
                        style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.w600),
                      ),
                      Text(
                        displayUrl,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: s.isBusy ? null : () => _openBackendConfigDialog(s),
                  child: const Text('Change'),
                ),
                TextButton(
                  onPressed:
                      s.isBusy ? null : widget.controller.checkServerConnection,
                  child: const Text('Test'),
                ),
              ],
            ),
            if (isNonHttpsRemote)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Warning: HTTP is only for local Wi-Fi development. Away-from-home mobile tracking requires a public HTTPS backend.',
                  style: TextStyle(fontSize: 12, color: Color(0xFFB45309)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusSummaryCard(DeviceTrackerState s) {
    final accuracyText = s.lastAccuracyMeters != null
        ? '±${s.lastAccuracyMeters!.round()} m'
        : '—';
    final uploadText = s.lastUploadAt != null
        ? _formatTime(s.lastUploadAt)
        : (s.hasPendingFix ? 'Queued (offline)' : 'None yet');

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
                StatusBadge(statusState: s.statusState),
                const SizedBox(width: 8),
                if (s.presenceMode != PresenceMode.unknown)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: s.presenceMode == PresenceMode.atHome
                          ? const Color(0xFFDCFCE7)
                          : const Color(0xFFE0F2FE),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      s.presenceMode.displayLabel(s.currentPlaceName),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: s.presenceMode == PresenceMode.atHome
                            ? const Color(0xFF166534)
                            : const Color(0xFF075985),
                      ),
                    ),
                  ),
                const Spacer(),
                if (s.isBusy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: InfoMetricTile(
                    label: 'Last Successful Upload',
                    value: uploadText,
                    highlight: s.hasPendingFix,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: InfoMetricTile(
                    label: 'GPS Accuracy',
                    value: accuracyText,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: InfoMetricTile(
                    label: 'Location Permission',
                    value: s.hasLocationPermission
                        ? (s.hasFineLocation ? 'Precise Granted' : 'Approx. Granted')
                        : 'Missing',
                    highlight: !s.hasLocationPermission,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: InfoMetricTile(
                    label: 'Network',
                    value: s.isNetworkConnected
                        ? s.networkType.toUpperCase()
                        : 'Offline',
                    highlight: !s.isNetworkConnected,
                  ),
                ),
              ],
            ),
            if (s.hasPendingFix) ...[
              const SizedBox(height: 10),
              Text(
                'Pending offline point (${_formatTime(s.pendingRecordedAt)}): newest fix saved locally and replaces older unsent fixes until network returns.',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF9A3412),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFamilyCircleCard(DeviceTrackerState s) {
    final circle = widget.controller.family.circle;
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
                const Icon(Icons.family_restroom, color: Color(0xFF0F766E)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    circle == null ? 'Family Circle' : circle.name,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (circle == null) ...[
              const Text(
                'Create a Family Circle to share your live location whenever you leave Home, or join an existing family using their invite code.',
                style: TextStyle(fontSize: 13, color: Color(0xFF475569)),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: s.isBusy ? null : () => _openCreateCircleDialog(s),
                      icon: const Icon(Icons.add_circle_outline),
                      label: const Text('Create Circle'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: s.isBusy ? null : () => _openJoinCircleDialog(s),
                      icon: const Icon(Icons.group_add_outlined),
                      label: const Text('Join Invite'),
                    ),
                  ),
                ],
              ),
            ] else ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF0FDF4),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFBBF7D0)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'SHAREABLE FAMILY INVITE CODE',
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF166534)),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            circle.inviteCode,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              fontFamily: 'monospace',
                              color: Color(0xFF14532D),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy invite code',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: circle.inviteCode));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Invite code copied!')),
                        );
                      },
                      icon: const Icon(Icons.copy, color: Color(0xFF166534)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: s.isBusy ? null : widget.controller.regenerateCircleInviteCode,
                    icon: const Icon(Icons.refresh, size: 17),
                    label: const Text('Rotate Code'),
                  ),
                  OutlinedButton.icon(
                    onPressed: s.isBusy ? null : widget.controller.leaveFamilyCircle,
                    icon: const Icon(Icons.exit_to_app, size: 17),
                    label: const Text('Leave Circle'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildUnregisteredCard(DeviceTrackerState s) {
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
            const Text(
              'Register This Device',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'No username, email, or password is required. Registering creates a private device key so you can join a Family Circle or pair with a laptop dashboard. Location sharing remains OFF until you explicitly grant permission and tap "Start sharing".',
              style: TextStyle(fontSize: 13, color: Color(0xFF475569)),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _deviceNameController,
              maxLength: 64,
              decoration: const InputDecoration(
                labelText: 'Device label shown to family',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: s.isBusy
                    ? null
                    : () => widget.controller.registerDevice(
                          customDeviceName: _deviceNameController.text,
                        ),
                icon: const Icon(Icons.phonelink_setup),
                label: const Text('Register this device'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSharingControlsCard(DeviceTrackerState s) {
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
            const Text(
              'Location Sharing Controls',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              'A persistent notification with a "Stop sharing" action stays visible whenever sharing runs in the background.',
              style: TextStyle(fontSize: 12, color: Color(0xFF475569)),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Smart Home Mode (Recommended)',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                'Show "At Home" inside the house (battery saver & privacy), then auto-track live GPS when out of the house.',
                style: TextStyle(fontSize: 12),
              ),
              value: s.smartHomeMode,
              onChanged: s.isBusy ? null : widget.controller.setSmartHomeMode,
            ),
            if (!s.hasLocationPermission) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFFCA5A5)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Location permission missing — sharing cannot begin until you grant access.',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF991B1B),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton(
                          onPressed: s.isBusy
                              ? null
                              : () async {
                                  final ok = await showPermissionRationaleDialog(context);
                                  if (ok) {
                                    await widget.controller.requestPermissionsFromOs();
                                  }
                                },
                          child: const Text('Grant Location Permission'),
                        ),
                        OutlinedButton(
                          onPressed: widget.controller.openAppSettings,
                          child: const Text('App Settings'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            if (!s.isLocationServiceEnabled) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: widget.controller.openLocationSettings,
                icon: const Icon(Icons.settings),
                label: const Text('Enable Device Location / GPS'),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                const Text(
                  'Away update rate:',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    isExpanded: true,
                    initialValue: const [15000, 30000, 60000].contains(s.updateIntervalMs)
                        ? s.updateIntervalMs
                        : 30000,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 15000, child: Text('Every 15s (Higher accuracy)')),
                      DropdownMenuItem(value: 30000, child: Text('Every 30s (Battery balanced)')),
                      DropdownMenuItem(value: 60000, child: Text('Every 60s (Battery saver)')),
                    ],
                    onChanged: s.isSharing
                        ? null
                        : (val) {
                            if (val != null) {
                              widget.controller.setUpdateIntervalMs(val);
                            }
                          },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: s.isBusy || s.isSharing
                        ? null
                        : () => _handleStartSharing(s),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start sharing'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: s.isBusy || !s.isSharing
                        ? null
                        : widget.controller.stopSharing,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop sharing'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPrivacyActionsCard(DeviceTrackerState s) {
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
            const Text(
              'Privacy & Control',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'Device ID: ${s.deviceId}',
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: Color(0xFF475569),
              ),
            ),
            const SizedBox(height: 12),
            if (!s.isSupabaseMode) ...[
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: s.isBusy ? null : _confirmAndRevokePairings,
                  icon: const Icon(Icons.link_off),
                  label: const Text('Revoke Dashboard Pairings'),
                ),
              ),
              const SizedBox(height: 8),
            ],
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: s.isBusy ? null : widget.controller.deleteStoredLocation,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete Stored Location'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFB91C1C),
                  side: const BorderSide(color: Color(0xFFFCA5A5)),
                ),
                onPressed: s.isBusy ? null : _confirmAndUnregister,
                icon: const Icon(Icons.phonelink_erase),
                label: const Text('Unregister this device'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBanner({
    required Color color,
    required Color borderColor,
    required Color textColor,
    required IconData icon,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: textColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                color: textColor,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
