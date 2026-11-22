import 'package:flutter/material.dart';

import 'screens/main_shell.dart';
import 'services/locashare_api.dart';
import 'services/location_controller.dart';
import 'services/native_bridge.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LocaShareApp());
}

class LocaShareApp extends StatefulWidget {
  const LocaShareApp({super.key});

  @override
  State<LocaShareApp> createState() => _LocaShareAppState();
}

class _LocaShareAppState extends State<LocaShareApp> {
  late final LocationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = LocationController(
      api: LocaShareApi(),
      bridge: MethodChannelNativeBridge(),
    );
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LocaShare Family',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F766E),
        ),
        useMaterial3: true,
      ),
      home: MainShell(controller: _controller),
    );
  }
}
