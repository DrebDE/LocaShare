import 'package:flutter/material.dart';

import '../services/location_controller.dart';
import 'family_map_screen.dart';
import 'home_screen.dart';
import 'places_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({
    super.key,
    required this.controller,
    this.initialTabIndex = 0,
    this.enableNetworkTiles = true,
  });

  final LocationController controller;
  final int initialTabIndex;
  final bool enableNetworkTiles;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  late int _tabIndex;

  @override
  void initState() {
    super.initState();
    _tabIndex = widget.initialTabIndex;
  }

  void _goToTab(int idx) {
    setState(() => _tabIndex = idx);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final eventsCount = widget.controller.family.events.length;
        return Scaffold(
          body: IndexedStack(
            index: _tabIndex,
            children: [
              FamilyMapScreen(
                controller: widget.controller,
                enableNetworkTiles: widget.enableNetworkTiles,
                onNavigateToCircleSetup: () => _goToTab(2),
                onNavigateToPlaces: () => _goToTab(1),
              ),
              PlacesScreen(
                controller: widget.controller,
                enableNetworkTiles: widget.enableNetworkTiles,
              ),
              HomeScreen(controller: widget.controller),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tabIndex,
            onDestinationSelected: _goToTab,
            destinations: [
              const NavigationDestination(
                icon: Icon(Icons.map_outlined),
                selectedIcon: Icon(Icons.map),
                label: 'Family Map',
              ),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: eventsCount > 0,
                  label: Text('$eventsCount'),
                  child: const Icon(Icons.place_outlined),
                ),
                selectedIcon: const Icon(Icons.place),
                label: 'Places & Alerts',
              ),
              const NavigationDestination(
                icon: Icon(Icons.family_restroom_outlined),
                selectedIcon: Icon(Icons.family_restroom),
                label: 'Circle & Device',
              ),
            ],
          ),
        );
      },
    );
  }
}
