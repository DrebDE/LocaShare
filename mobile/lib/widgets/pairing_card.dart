import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'qr_matrix.dart';

class PairingCodeCard extends StatelessWidget {
  const PairingCodeCard({
    super.key,
    required this.pairingCode,
    required this.qrPayload,
    required this.secondsRemaining,
    required this.pairedDashboardsCount,
    required this.isBusy,
    required this.onGenerateNewCode,
    required this.onRefreshStatus,
  });

  final String? pairingCode;
  final String? qrPayload;
  final int secondsRemaining;
  final int pairedDashboardsCount;
  final bool isBusy;
  final VoidCallback onGenerateNewCode;
  final VoidCallback onRefreshStatus;

  String _formatCountdown(int seconds) {
    if (seconds <= 0) return 'Expired';
    final mins = seconds ~/ 60;
    final rem = seconds % 60;
    return '${mins.toString().padLeft(2, '0')}:${rem.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final code = pairingCode;
    final hasActive = code != null && code.isNotEmpty && secondsRemaining > 0;
    final payload = (qrPayload != null && qrPayload!.isNotEmpty)
        ? qrPayload!
        : (code != null ? 'locashare://pair?code=$code' : '');

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
                const Expanded(
                  child: Text(
                    'Pair to Laptop Dashboard',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: pairedDashboardsCount > 0
                        ? const Color(0xFFDCFCE7)
                        : const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$pairedDashboardsCount dashboard${pairedDashboardsCount == 1 ? '' : 's'} paired',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: pairedDashboardsCount > 0
                          ? const Color(0xFF166534)
                          : const Color(0xFF475569),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Open the LocaShare dashboard in your laptop browser and enter this one-time code or scan the QR code.',
              style: TextStyle(fontSize: 13, color: Color(0xFF475569)),
            ),
            const SizedBox(height: 14),
            if (hasActive) ...[
              Center(
                child: Column(
                  children: [
                    QrCodeView(data: payload, size: 176),
                    const SizedBox(height: 12),
                    SelectableText(
                      code,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 3,
                        fontFamily: 'monospace',
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Single-use code expires in ${_formatCountdown(secondsRemaining)}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF0F766E),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: code));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Copied one-time pairing code.'),
                          ),
                        );
                      },
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copy Code'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: isBusy ? null : onGenerateNewCode,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('New Code'),
                    ),
                  ),
                ],
              ),
            ] else ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: const Text(
                  'No active one-time pairing code is currently shown. Generate a fresh 5-minute code whenever you want to link another laptop browser.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF475569)),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: isBusy ? null : onGenerateNewCode,
                      icon: const Icon(Icons.qr_code, size: 18),
                      label: const Text('Generate Pairing Code'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Refresh pairing count',
                    onPressed: isBusy ? null : onRefreshStatus,
                    icon: const Icon(Icons.sync),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
