import 'package:flutter/material.dart';
import 'package:map_engine/map_engine.dart';

class UIShell extends StatefulWidget {
  const UIShell({super.key});

  @override
  State<UIShell> createState() => _UIShellState();
}

class _UIShellState extends State<UIShell> {
  int _selectedIndex = 0;

  static const List<Widget> _pages = [
    MapScreen(),
    Center(child: Text('Trips – coming soon', style: TextStyle(color: Colors.white))),
    Center(child: Text('Settings – coming soon', style: TextStyle(color: Colors.white))),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        backgroundColor: const Color(0xFF0f1220),
        title: const Text(
          'LYNX Bus Boss',
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 18,
            letterSpacing: 2,
            color: Color(0xFF00e5ff),
          ),
        ),
      ),
      body: _pages[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (i) => setState(() => _selectedIndex = i),
        backgroundColor: const Color(0xFF0f1220),
        selectedItemColor: const Color(0xFF00e5ff),
        unselectedItemColor: const Color(0xFF5a6380),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.map),
            label: 'Map',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.schedule),
            label: 'Trips',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
