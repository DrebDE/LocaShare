import 'package:flutter/material.dart';

/// Shows an honest, plain-language explanation before triggering Android's
/// system location permission prompt.
Future<bool> showPermissionRationaleDialog(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Location Permission Needed'),
      content: const SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'LocaShare needs permission to read this phone\'s location only while you actively choose to share it.',
            ),
            SizedBox(height: 10),
            Text(
              '• Sharing never starts automatically — it begins only when you tap "Start sharing".',
            ),
            SizedBox(height: 6),
            Text(
              '• LocaShare only requests Location access and can be paused anytime with "Stop sharing".',
            ),
            SizedBox(height: 6),
            Text(
              '• Your configured LocaShare backend stores only your latest coordinate by default (no route history).',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Not Now'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  return confirmed == true;
}
