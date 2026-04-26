import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class MapScreen extends StatelessWidget {
  const MapScreen({super.key});

  /// You can change this URL to any tile style you like.
  /// This one is Stadia Alidade Smooth (free tier) – clean, Google-like style.
  static const _tileUrl =
      'https://tiles.stadiamaps.com/tiles/alidade_smooth/{z}/{x}/{y}{r}.png';

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        FlutterMap(
          options: MapOptions(
            initialCenter: LatLng(28.5383, -81.3792), // Orlando
            initialZoom: 13.2,
          ),
          children: [
            TileLayer(
              urlTemplate: _tileUrl,
              userAgentPackageName: 'com.busboss.bus_boss_v2',
              // Replace with your Stadia Maps API key if needed, or switch to OSM
              // additionalOptions: const {'api_key': 'YOUR_KEY'},
            ),
          ],
        ),
        // Search bar overlay at the top
        Positioned(
          top: 16,
          left: 16,
          right: 16,
          child: Card(
            elevation: 8,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            color: const Color(0xFF1e2640),
            child: const TextField(
              style: TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Search destination…',
                hintStyle: TextStyle(color: Color(0xFF5a6380)),
                prefixIcon:
                    Icon(Icons.search, color: Color(0xFF00e5ff)),
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
