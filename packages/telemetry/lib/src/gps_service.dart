import 'dart:async';
import 'package:contracts/contracts.dart';
import 'package:geolocator/geolocator.dart';

/// Provides a stream of location updates from the device GPS.
class GpsService {
  final _controller = StreamController<LocationUpdate>.broadcast();
  StreamSubscription<Position>? _subscription;

  Stream<LocationUpdate> get locationStream => _controller.stream;

  /// Start listening with desired accuracy and distance filter.
  void start({
    int distanceFilterMeters = 10,
    LocationAccuracy accuracy = LocationAccuracy.high,
  }) {
    _subscription = Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilterMeters,
      ),
    ).listen((position) {
      _controller.add(LocationUpdate(
        lat: position.latitude,
        lon: position.longitude,
        speed: position.speed,
        accuracy: position.accuracy,
        timestamp: position.timestamp ?? DateTime.now(),
      ));
    });
  }

  /// Stop listening.
  void stop() {
    _subscription?.cancel();
    _subscription = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
