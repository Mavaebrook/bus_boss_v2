import 'dart:async';
import 'package:contracts/contracts.dart';
import 'package:geolocator/geolocator.dart';

/// Provides a stream of location updates from the device GPS.
class GpsService {
  final _controller = StreamController<LocationUpdate>.broadcast();
  StreamSubscription<Position>? _subscription;
  bool _isDisposed = false;

  Stream<LocationUpdate> get locationStream => _controller.stream;

  /// Start listening with desired accuracy and distance filter.
  Future<void> start({
    int distanceFilterMeters = 10,
    LocationAccuracy accuracy = LocationAccuracy.high,
  }) async {
    if (_isDisposed) return;

    // Logic Correction: Ensure previous subscriptions are cleaned up
    await stop();

    // Logic Correction: Check/Request permissions before listening
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _controller.addError('Location services are disabled.');
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        _controller.addError('Location permissions are denied.');
        return;
      }
    }

    _subscription = Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilterMeters,
      ),
    ).listen(
      (position) {
        if (_controller.isClosed) return;
        
        _controller.add(LocationUpdate(
          lat: position.latitude,
          lon: position.longitude,
          speed: position.speed,
          accuracy: position.accuracy,
          // Ensuring we use the precise GPS clock time
          timestamp: position.timestamp,
        ));
      },
      onError: (error) {
        _controller.addError(error);
      },
      cancelOnError: false,
    );
  }

  /// Stop listening and clear the subscription reference.
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  /// Permanently closes the service.
  void dispose() {
    _isDisposed = true;
    stop();
    _controller.close();
  }
}
