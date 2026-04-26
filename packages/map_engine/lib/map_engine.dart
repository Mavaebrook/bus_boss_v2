import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:user_input/user_input.dart';
import 'package:transit_query_engine/transit_query_engine.dart';
import 'package:telemetry/telemetry.dart';
import 'package:geolocator/geolocator.dart';
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
    _requestLocationAndStartGps();
  }

  Future<void> _requestLocationAndStartGps() async {
    final permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always) {
      _gpsService.start(distanceFilterMeters: 10);
      _locationSub = _gpsService.locationStream.listen((pos) {
        final userLoc = LatLng(pos.lat, pos.lon);
        if (mounted) {
          setState(() {
            _origin = userLoc;
            _currentCenter = userLoc;
          });
        }
      });
    } else {
      if (mounted) {
        setState(() {
          _origin = _currentCenter;
        });
      }
    }
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
    if (results.isEmpty) {
      _showMessage('No results found. Try a different query.');
    }
  }

  Future<void> _selectDestination(Map<String, dynamic> place) async {
    print('🔷 _selectDestination called for: ${place['displayName']}');
    final lat = place['lat'] as double;
    final lon = place['lon'] as double;
    final engine = ref.read(transitQueryEngineProvider);
    print('🔷 Engine obtained, dbPath: ${engine.dbPath}');

    // Snap destination to a stop
    final destStop = engine.snapToRoute(lat, lon);
    print('🔷 snapToRoute destination returned: $destStop');
    if (destStop == null) {
      _showMessage('Could not find a nearby stop for this destination.');
      return;
    }

    // Determine origin stop
    String originStopId;
    if (_origin != null) {
      final originStop = engine.snapToRoute(_origin!.latitude, _origin!.longitude);
      print('🔷 snapToRoute origin returned: $originStop');
      if (originStop != null) {
        originStopId = originStop['stop_id']!;
      } else {
        _showMessage('Could not find a nearby stop at your location.');
        return;
      }
    } else {
      final centreStop = engine.snapToRoute(_currentCenter.latitude, _currentCenter.longitude);
      if (centreStop == null) {
        _showMessage('Could not find any stops near the map centre.');
        return;
      }
      originStopId = centreStop['stop_id']!;
    }
    print('🔷 Using origin stop id: $originStopId, destination stop id: ${destStop['stop_id']}');

    // Get trip plan
    final plan = engine.getTripPlan(
      originStopId,
      destStop['stop_id']!,
      deadline: DateTime.now().add(const Duration(hours: 2)),
    );
    print('🔷 getTripPlan returned: $plan');
    if (plan == null) {
      _showMessage('No trip found. The service may not be running now.');
      return;
    }

    // Decode route geometry
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

  void _showMessage(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg, style: const TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF1e2640),
      ));
  }

  void _showTripSummary() {
    // … same as before …
  }

  @override
  Widget build(BuildContext context) {
    // … same as before …
  }
}
