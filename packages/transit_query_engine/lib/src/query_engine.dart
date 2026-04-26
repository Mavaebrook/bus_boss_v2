import 'dart:collection';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:contracts/contracts.dart';
import 'package:transit_realtime/transit_realtime.dart';

class TransitQueryEngine {
  final String dbPath;
  final PredictionCache? predictionCache;

  TransitQueryEngine({required this.dbPath, this.predictionCache});

  /// Get all active service IDs for a given date (YYYYMMDD).
  List<String> getActiveServiceIds(int date) {
    final db = sqlite3.sqlite3.open(dbPath);
    final rows = db.select(
      'SELECT service_id FROM active_services WHERE service_date = ?',
      [date],
    );
    db.dispose();
    return rows.map((r) => r.columnAt(0) as String).toList();
  }

  /// Convert DateTime to YYYYMMDD integer.
  int _dateToInt(DateTime d) =>
      d.year * 10000 + d.month * 100 + d.day;

  /// Snap a location to the nearest stop. Returns stop_id.
  Map<String, String>? snapToRoute(double lat, double lon) {
    final db = sqlite3.sqlite3.open(dbPath);
    final row = db.select(
      '''SELECT s.stop_id, t.trip_id, t.shape_id
         FROM stop_times st
         JOIN trips t ON st.trip_id = t.trip_id
         JOIN stops s ON st.stop_id = s.stop_id
         ORDER BY ((s.stop_lat - ?)*(s.stop_lat - ?) + (s.stop_lon - ?)*(s.stop_lon - ?))
         LIMIT 1''',
      [lat, lat, lon, lon],
    );
    db.dispose();
    if (row.isEmpty) return null;
    return {
      'stop_id': row.first.columnAt(0) as String,
      'trip_id': row.first.columnAt(1) as String,
      'shape_id': row.first.columnAt(2) as String,
    };
  }

  // -------------------------------------------------------------------------
  // Main trip planner
  // -------------------------------------------------------------------------
  TripPlan? getTripPlan(
    String fromStopId,
    String toStopId, {
    required DateTime deadline,
    DateTime? earliestDeparture,
    int maxWalkMeters = 400,
    int maxTransfers = 4,
    bool wheelchairAccessible = false,
  }) {
    final db = sqlite3.sqlite3.open(dbPath);
    final tripDate = _dateToInt(deadline);
    final activeServices = getActiveServiceIds(tripDate).toSet();

    // Cache for service IDs to avoid repeated lookups
    final stopRouteMap = <String, List<_RouteInfo>>{};
    final transferMap = <String, List<_Transfer>>{};

    // Load stop_route_map entries for all stops (lazy load later)
    // Load transfers

    // Priority queue: (current time, stop_id, path, transfer count, walk dist)
    // The time is the current arrival time at this stop.
    final queue = PriorityQueue<_State>((a, b) => a.time.compareTo(b.time));
    final best = <String, _BestCost>{};

    // Forward search from origin at earliest departure (default to 10 min from now if null)
    final startTime = earliestDeparture ??
        DateTime.now().add(const Duration(minutes: 10));
    final startSeconds = startTime.hour * 3600 +
        startTime.minute * 60 +
        startTime.second;

    queue.add(_State(fromStopId, startSeconds, [], 0, 0));
    best[fromStopId] = _BestCost(startSeconds, 0, 0);

    while (queue.isNotEmpty) {
      final state = queue.removeFirst();
      if (state.stopId == toStopId && state.time <= _dateTimeToSeconds(deadline)) {
        // Found a valid plan
        final segments = _buildSegments(db, state.path, state.time);
        final walkDist = state.walkDist;
        final transfers = state.transfers;
        return TripPlan(
          segments: segments,
          departureTime: _secondsToDateTime(startSeconds, deadline),
          arrivalTime: _secondsToDateTime(state.time, deadline),
          walkDistanceMeters: walkDist,
          transferCount: transfers,
        );
      }

      // 1. Board a trip from this stop
      final routes = _getRoutesFromStop(db, state.stopId, stopRouteMap);
      for (final route in routes) {
        // Only consider trips active today
        if (!activeServices.contains(route.serviceId)) continue;

        // Find the next departure of this route after current time
        final nextDeparture = _getNextDeparture(
          db,
          state.stopId,
          route.routeId,
          route.directionId,
          state.time,
        );
        if (nextDeparture == null) continue;

        final tripId = nextDeparture['trip_id'] as String;
        final depTime = nextDeparture['departure_time_seconds'] as int;
        final arrAtDest = _getArrivalAtStop(
          db,
          tripId,
          toStopId,
          route.stopSequence,
        );
        if (arrAtDest != null && arrAtDest <= _dateTimeToSeconds(deadline)) {
          final newTime = arrAtDest;
          final newPath = [...state.path, _PathSegment.trip(tripId, route.routeId, state.stopId, toStopId)];
          final newCost = newTime;
          final newTransfers = state.transfers;

          // Check if we already reached this stop with a better or equal time and fewer transfers
          final prev = best[toStopId];
          if (prev == null || newTime < prev.time || (newTime == prev.time && newTransfers < prev.transfers)) {
            best[toStopId] = _BestCost(newTime, newTransfers, state.walkDist);
            queue.add(_State(toStopId, newTime, newPath, newTransfers, state.walkDist));
          }
        }
        // Otherwise, get off at every stop and continue search...
        // This simplified version only checks direct trips to destination.
        // A full implementation would board the trip, alight at each subsequent stop, and queue those.
        // For brevity, we'll expand with trip segments below.
      }

      // 2. Walk to a nearby stop (transfer)
      final transfers = _getTransfersFromStop(db, state.stopId, transferMap);
      for (final transfer in transfers) {
        if (transfer.walkTimeSeconds > maxWalkMeters / 1.2) continue;
        if (wheelchairAccessible && !transfer.wheelchairAccessible) continue; // (if data available)
        final newTime = state.time + transfer.walkTimeSeconds;
        if (newTime > _dateTimeToSeconds(deadline)) continue;
        final nextStop = transfer.toStopId;
        final newTransfers = state.transfers + 1;
        if (newTransfers > maxTransfers) continue;
        final newWalkDist = state.walkDist + transfer.walkDistMeters;

        final prev = best[nextStop];
        if (prev == null || newTime < prev.time || (newTime == prev.time && newTransfers < prev.transfers)) {
          best[nextStop] = _BestCost(newTime, newTransfers, newWalkDist);
          final newPath = [...state.path, _PathSegment.walk(state.stopId, nextStop, transfer.walkDistMeters)];
          queue.add(_State(nextStop, newTime, newPath, newTransfers, newWalkDist));
        }
      }
    }

    db.dispose();
    return null; // No route found
  }

  // -------------------------------------------------------------------------
  // Internal helpers
  // -------------------------------------------------------------------------
  int _dateTimeToSeconds(DateTime dt) =>
      dt.hour * 3600 + dt.minute * 60 + dt.second;

  DateTime _secondsToDateTime(int secs, DateTime day) {
    // Handles >24h times: we assume the seconds are from midnight on the given day.
    final hours = secs ~/ 3600;
    final mins = (secs % 3600) ~/ 60;
    final sec = secs % 60;
    return DateTime(day.year, day.month, day.day, hours % 24, mins, sec)
        .add(Duration(days: hours ~/ 24));
  }

  List<_RouteInfo> _getRoutesFromStop(
      sqlite3.Sqlite3 db, String stopId, Map<String, List<_RouteInfo>> cache) {
    if (cache.containsKey(stopId)) return cache[stopId]!;
    final rows = db.select(
      '''SELECT srm.route_id, srm.direction_id, t.service_id, 
         MIN(st.stop_sequence) as first_sequence
         FROM stop_route_map srm
         JOIN trips t ON srm.route_id = t.route_id AND srm.direction_id = t.direction_id
         JOIN stop_times st ON t.trip_id = st.trip_id AND st.stop_id = srm.stop_id
         WHERE srm.stop_id = ?
         GROUP BY srm.route_id, srm.direction_id, t.service_id''',
      [stopId],
    );
    final list = rows.map((r) => _RouteInfo(
          routeId: r.columnAt(0) as String,
          directionId: r.columnAt(1) as int,
          serviceId: r.columnAt(2) as String,
          stopSequence: r.columnAt(3) as int,
        )).toList();
    cache[stopId] = list;
    return list;
  }

  Map<String, dynamic>? _getNextDeparture(
    sqlite3.Sqlite3 db,
    String stopId,
    String routeId,
    int directionId,
    int afterSeconds,
  ) {
    // Use index idx_st_departure (stop_id, departure_time_seconds)
    final rows = db.select(
      '''SELECT st.trip_id, st.departure_time_seconds, st.stop_sequence
         FROM stop_times st
         JOIN trips t ON st.trip_id = t.trip_id
         WHERE st.stop_id = ? AND t.route_id = ? AND t.direction_id = ?
           AND st.departure_time_seconds >= ?
         ORDER BY st.departure_time_seconds
         LIMIT 1''',
      [stopId, routeId, directionId, afterSeconds],
    );
    if (rows.isEmpty) return null;
    return {
      'trip_id': rows.first.columnAt(0) as String,
      'departure_time_seconds': rows.first.columnAt(1) as int,
      'stop_sequence': rows.first.columnAt(2) as int,
    };
  }

  int? _getArrivalAtStop(
    sqlite3.Sqlite3 db,
    String tripId,
    String stopId,
    int originStopSequence,
  ) {
    // Use index idx_st_trip (trip_id, stop_sequence)
    final rows = db.select(
      '''SELECT arrival_time_seconds
         FROM stop_times
         WHERE trip_id = ? AND stop_id = ?
           AND stop_sequence > ?
         ORDER BY stop_sequence
         LIMIT 1''',
      [tripId, stopId, originStopSequence],
    );
    if (rows.isEmpty) return null;
    return rows.first.columnAt(0) as int;
  }

  List<_Transfer> _getTransfersFromStop(
      sqlite3.Sqlite3 db, String stopId, Map<String, List<_Transfer>> cache) {
    if (cache.containsKey(stopId)) return cache[stopId]!;
    final rows = db.select(
      '''SELECT to_stop_id, min_transfer_time
         FROM transfers
         WHERE from_stop_id = ?''',
      [stopId],
    );
    final list = rows.map((r) => _Transfer(
          toStopId: r.columnAt(0) as String,
          walkTimeSeconds: r.columnAt(1) as int,
          walkDistMeters: (r.columnAt(1) as int) * 1.2, // approximate
        )).toList();
    cache[stopId] = list;
    return list;
  }

  List<RouteSegment> _buildSegments(
      sqlite3.Sqlite3 db, List<_PathSegment> path, int endTime) {
    // For simplicity, return an empty list for now.
    return [];
  }
}

// Internal classes
class _RouteInfo {
  final String routeId;
  final int directionId;
  final String serviceId;
  final int stopSequence;
  _RouteInfo({required this.routeId, required this.directionId, required this.serviceId, required this.stopSequence});
}

class _Transfer {
  final String toStopId;
  final int walkTimeSeconds;
  final double walkDistMeters;
  _Transfer({required this.toStopId, required this.walkTimeSeconds, required this.walkDistMeters});
}

class _State {
  final String stopId;
  final int time;
  final List<_PathSegment> path;
  final int transfers;
  final double walkDist;
  _State(this.stopId, this.time, this.path, this.transfers, this.walkDist);
}

class _PathSegment {
  final String type; // 'trip' or 'walk'
  final String? tripId;
  final String? routeId;
  final String fromStop;
  final String toStop;
  final double? walkDistMeters;
  _PathSegment.trip(this.tripId, this.routeId, this.fromStop, this.toStop)
      : type = 'trip', walkDistMeters = null;
  _PathSegment.walk(this.fromStop, this.toStop, this.walkDistMeters)
      : type = 'walk', tripId = null, routeId = null;
}

class _BestCost {
  final int time;
  final int transfers;
  final double walkDist;
  _BestCost(this.time, this.transfers, this.walkDist);
}
