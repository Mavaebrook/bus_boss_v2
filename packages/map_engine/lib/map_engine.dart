import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:user_input/user_input.dart';
import 'package:transit_query_engine/transit_query_engine.dart';
import 'package:telemetry/telemetry.dart';
import 'package:contracts/contracts.dart';
import 'polyline_decoder.dart';

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  final _searchController = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];
  bool _searching = false;
  TripPlan? _tripPlan;
  LatLng? _origin;
  LatLng? _destination;
  List<LatLng> _routePoints = [];
  LatLng _currentCenter = const LatLng(28.5383, -81.3792);

  StreamSubscription<LocationUpdate>? _locationSub;
  final GpsService _gpsService = GpsService();

  @override
  void initState() {
    super.initState();
    _gpsService.start(distanceFilterMeters: 10);
    _locationSub = _gpsService.locationStream.listen((pos) {
      final userLoc = LatLng(pos.lat, pos.lon);
      final engine = ref.read(transitQueryEngineProvider);
      final stop = engine.snapToRoute(pos.lat, pos.lon);
      if (stop != null && mounted) {
        setState(() {
          _origin = userLoc;
          _currentCenter = userLoc;
        });
      }
    });
  }

  @override
  void dispose() {
    _locationSub?.cancel();
    _gpsService.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _performSearch(String query) async {
    if (query.isEmpty) return;
    setState(() => _searching = true);
    final service = GeocodingService();
    final results = await service.search(query);
    setState(() {
      _searchResults = results;
      _searching = false;
    });
  }

  Future<void> _selectDestination(Map<String, dynamic> place) async {
    final lat = place['lat'] as double;
    final lon = place['lon'] as double;
    final engine = ref.read(transitQueryEngineProvider);

    final destStop = engine.snapToRoute(lat, lon);
    if (destStop == null) return;

    String originStopId = '2001';
    if (_origin != null) {
      final originStop = engine.snapToRoute(_origin!.latitude, _origin!.longitude);
      if (originStop != null) {
        originStopId = originStop['stop_id']!;
      }
    }

    final plan = engine.getTripPlan(
      originStopId,
      destStop['stop_id']!,
      deadline: DateTime.now().add(const Duration(hours: 2)),
    );
    if (plan == null) return;

    final List<LatLng> fullRoute = [];
    for (final seg in plan.segments) {
      if (seg.geometryPolyline != null && seg.geometryPolyline!.isNotEmpty) {
        final decoded = decodePolyline(seg.geometryPolyline!);
        for (final p in decoded) {
          fullRoute.add(LatLng(p[0], p[1]));
        }
      }
    }

    setState(() {
      _destination = LatLng(lat, lon);
      _tripPlan = plan;
      _routePoints = fullRoute;
      _searchResults = [];
      _searchController.clear();
    });
    _showTripSummary();
  }

  void _showTripSummary() {
    if (_tripPlan == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0f1220),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final plan = _tripPlan!;
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Trip Summary',
                style: TextStyle(
                    color: Color(0xFF00e5ff),
                    fontSize: 18,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(
                'Depart: ${plan.departureTime.hour}:${plan.departureTime.minute.toString().padLeft(2,'0')}',
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              Text(
                'Arrive: ${plan.arrivalTime.hour}:${plan.arrivalTime.minute.toString().padLeft(2,'0')}',
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              Text(
                'Transfers: ${plan.transferCount}',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              Text(
                'Walk: ${plan.walkDistanceMeters.toStringAsFixed(0)}m',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 16),
              if (plan.segments.isNotEmpty)
                ...plan.segments.map((s) => ListTile(
                      dense: true,
                      leading: Icon(
                          s.geometryPolyline != null
                              ? Icons.directions_bus
                              : Icons.directions_walk,
                          color: const Color(0xFF00e5ff)),
                      title: Text(
                        s.geometryPolyline != null
                            ? 'Bus ${s.routeId}'
                            : 'Walk ${s.toStopId}',
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: Text(
                        '${s.departureSeconds ~/ 3600}:${((s.departureSeconds % 3600) / 60).floor().toString().padLeft(2,'0')}'
                        ' → ${s.arrivalSeconds ~/ 3600}:${((s.arrivalSeconds % 3600) / 60).floor().toString().padLeft(2,'0')}',
                        style: const TextStyle(color: Colors.white54),
                      ),
                    )),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final map = FlutterMap(
      options: MapOptions(
        initialCenter: _currentCenter,
        initialZoom: 13.2,
      ),
      children: [
        TileLayer(
          urlTemplate:
              'https://a.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png',
          userAgentPackageName: 'com.busboss.bus_boss_v2',
        ),
        if (_routePoints.isNotEmpty)
          PolylineLayer(polylines: [
            Polyline(
                points: _routePoints,
                color: const Color(0xFF00e5ff),
                strokeWidth: 5)
          ]),
        if (_origin != null)
          MarkerLayer(markers: [
            Marker(
                point: _origin!,
                child: const Icon(Icons.my_location,
                    color: Colors.blue, size: 28))
          ]),
        if (_destination != null)
          MarkerLayer(markers: [
            Marker(
                point: _destination!,
                child: const Icon(Icons.flag, color: Colors.red, size: 32))
          ]),
      ],
    );

    return Stack(
      children: [
        map,
        Positioned(
          top: 16,
          left: 16,
          right: 16,
          child: Column(children: [
            Card(
              elevation: 8,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              color: const Color(0xFF1e2640),
              child: TextField(
                controller: _searchController,
                style: const TextStyle(color: Colors.white),
                onChanged: (v) => _performSearch(v),
                decoration: const InputDecoration(
                  hintText: 'Search destination…',
                  hintStyle: TextStyle(color: Color(0xFF5a6380)),
                  prefixIcon:
                      Icon(Icons.search, color: Color(0xFF00e5ff)),
                  border: InputBorder.none,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
              ),
            ),
            if (_searching)
              const Padding(
                padding: EdgeInsets.all(8.0),
                child: CircularProgressIndicator(),
              ),
            if (_searchResults.isNotEmpty)
              Card(
                elevation: 8,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                color: const Color(0xFF1e2640),
                child: Column(
                  children: _searchResults
                      .map((r) => ListTile(
                            dense: true,
                            title: Text(
                              r['displayName'] as String,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 12),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => _selectDestination(r),
                          ))
                      .toList(),
                ),
              ),
          ]),
        ),
      ],
    );
  }
}
