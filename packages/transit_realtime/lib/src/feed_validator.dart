import 'package:gtfs_realtime/gtfs_realtime.pb.dart' as pb;

class FeedValidator {
  /// Must have trip_id, lat, lon.
  static bool isValidVehicle(pb.VehiclePosition vp) {
    if (!vp.hasTrip() || !vp.trip.hasTripId()) return false;
    if (!vp.hasPosition()) return false;
    if (!vp.position.hasLatitude() || !vp.position.hasLongitude()) return false;
    return true;
  }

  /// Must have trip_id and at least one stop with stop_id.
  static bool isValidTripUpdate(pb.TripUpdate tu) {
    if (!tu.hasTrip() || !tu.trip.hasTripId()) return false;
    if (tu.stopTimeUpdate.isEmpty) return false;
    if (!tu.stopTimeUpdate.any((stu) => stu.hasStopId())) return false;
    return true;
  }

  /// At least one stop_time_update contains a time.
  static bool hasPredictionTime(pb.TripUpdate tu) {
    return tu.stopTimeUpdate.any((stu) =>
        (stu.hasArrival() && stu.arrival.hasTime()) ||
        (stu.hasDeparture() && stu.departure.hasTime()));
  }
}
