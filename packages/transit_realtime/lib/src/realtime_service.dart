import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart' as pb;
import 'feed_validator.dart';

/// Fetches GTFS-RT data and emits validated vehicle/trip update streams.
class RealtimeService {
  final String vehiclePositionsUrl;
  final String tripUpdatesUrl;
  final Duration pollInterval;

  final _vehiclePositionsController =
      StreamController<List<pb.VehiclePosition>>.broadcast();
  final _tripUpdatesController =
      StreamController<List<pb.TripUpdate>>.broadcast();

  Timer? _timer;

  RealtimeService({
    required this.vehiclePositionsUrl,
    required this.tripUpdatesUrl,
    this.pollInterval = const Duration(seconds: 30),
  });

  Stream<List<pb.VehiclePosition>> get vehiclePositions =>
      _vehiclePositionsController.stream;
  Stream<List<pb.TripUpdate>> get tripUpdates =>
      _tripUpdatesController.stream;

  void start() {
    _timer = Timer.periodic(pollInterval, (_) => _fetchFeeds());
    _fetchFeeds();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _fetchFeeds() async {
    try {
      final responses = await Future.wait([
        http.get(Uri.parse(vehiclePositionsUrl)),
        http.get(Uri.parse(tripUpdatesUrl)),
      ]);

      final vp = _parseVehiclePositions(responses[0].bodyBytes);
      final tu = _parseTripUpdates(responses[1].bodyBytes);

      _vehiclePositionsController.add(vp);
      _tripUpdatesController.add(tu);
    } catch (e) {
      // Feed failure should never crash the app.
      print('GTFS-RT fetch/parse error: $e');
    }
  }

  List<pb.VehiclePosition> _parseVehiclePositions(List<int> bytes) {
    try {
      final feed = pb.FeedMessage.fromBuffer(bytes);
      return feed.entity
          .where((e) => e.hasVehicle())
          .map((e) => e.vehicle)
          .where((vp) => FeedValidator.isValidVehicle(vp))
          .toList();
    } catch (e) {
      print('Vehicle position parsing error: $e');
      return [];
    }
  }

  List<pb.TripUpdate> _parseTripUpdates(List<int> bytes) {
    try {
      final feed = pb.FeedMessage.fromBuffer(bytes);
      return feed.entity
          .where((e) => e.hasTripUpdate())
          .map((e) => e.tripUpdate)
          .where((tu) => FeedValidator.isValidTripUpdate(tu))
          .toList();
    } catch (e) {
      print('Trip update parsing error: $e');
      return [];
    }
  }
}
