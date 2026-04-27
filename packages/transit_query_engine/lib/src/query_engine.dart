import 'package:collection/collection.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:contracts/contracts.dart';
import 'package:transit_realtime/transit_realtime.dart';

class TransitQueryEngine {
  final String dbPath;
  final PredictionCache? predictionCache;

  TransitQueryEngine({required this.dbPath, this.predictionCache});

  // -------------------------------------------------------------------------
  // Date helpers
  // -------------------------------------------------------------------------
  List<String> getActiveServiceIds(int date) {
    final db = sqlite3.sqlite3.open(dbPath);
    try {
      return _getActiveServiceIdsWithDb(db, date);
    } finally {
      db.dispose();
    }
  }

  List<String> _getActiveServiceIdsWithDb(sqlite3.Database db, int date) {
    final rows = db.select(
      'SELECT service_id FROM active_services WHERE service_date = ?',
      [date],
    );
    return rows.map((r) => r['service_id'] as String).toList();
  }

  int _dateToInt(DateTime d) =>
      d.year * 10000 + d.month * 100 + d.day;

  /// Calculates seconds relative to the midnight of [baseDate] to prevent 
  /// wraparound bugs when a trip crosses midnight into the next day.
  int _dateTimeToSeconds(DateTime dt, DateTime baseDate) {
    final baseMidnight = DateTime(baseDate.year, baseDate.month, baseDate.day);
    final targetMidnight = DateTime(dt.year, dt.month, dt.day);
    final daysDiff = targetMidnight.difference(baseMidnight).inDays;
    
    return (daysDiff * 86400) + (dt.hour * 3600) + (dt.minute * 60) + dt.second;
  }

  DateTime _secondsToDateTime(int secs, DateTime baseDate) {
    final hours = secs ~/ 3600;
    final mins = (secs % 3600) ~/ 60;
    final sec = secs % 60;
    return DateTime(baseDate.year, baseDate.month, baseDate.day, hours % 24, mins, sec)
        .add(Duration(days: hours ~/ 24));
  }

  // -------------------------------------------------------------------------
  // Snap to nearest stop
  // -------------------------------------------------------------------------
  Map<String, String>? snapToRoute(double lat, double lon) {
    print('🔍 snapToRoute($lat, $lon)  dbPath=$dbPath');
    final db = sqlite3.sqlite3.open(dbPath);
    
    try {
      final row = db.select(
        '''SELECT s.stop_id, t.trip_id, t.shape_id
           FROM stop_times st
           JOIN trips t ON st.trip_id = t.trip_id
           JOIN stops s ON st.stop_id = s.stop_id
           ORDER BY ((s.stop_lat - ?)*(s.stop_lat - ?) + (s.stop_lon - ?)*(s.stop_lon - ?))
           LIMIT 1''',
        [lat, lat, lon, lon],
      );
      
      print('🔍 snapToRoute query returned ${row.length} rows');
      if (row.isEmpty) return null;
      
      final result = {
        'stop_id': row.first['stop_id'] as String,
        'trip_id': row.first['trip_id'] as String,
        'shape_id': row.first['shape_id'] as String,
      };
      
      print('🔍 snapToRoute result: $result');
      return result;
    } finally {
      db.dispose();
    }
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
    
    try {
      final baseDate = earliestDeparture ?? DateTime.now();
      final startTime = earliestDeparture ?? DateTime.now().add(const Duration(minutes: 10));
      
      final tripDate = _dateToInt(baseDate);
      final activeServices = _getActiveServiceIdsWithDb(db, tripDate).toSet();

      final stopRouteMap = <String, List<_RouteInfo>>{};
      final transferMap = <String, List<_Transfer>>{};

      final queue = PriorityQueue<_State>((a, b) => a.time.compareTo(b.time));
      final best = <String, _BestCost>{};

      final startSeconds = _dateTimeToSeconds(startTime, baseDate);
      final deadlineSeconds = _dateTimeToSeconds(deadline, baseDate);

      queue.add(_State(fromStopId, startSeconds, [], 0, 0));
      best[fromStopId] = _BestCost(startSeconds, 0, 0);

      while (queue.isNotEmpty) {
        final state = queue.removeFirst();

        if (state.stopId == toStopId && state.time <= deadlineSeconds) {
          final segments = _buildSegments(db, state.path, state.time, baseDate);
          return TripPlan(
            segments: segments,
            departureTime: _secondsToDateTime(startSeconds, baseDate),
            arrivalTime: _secondsToDateTime(state.time, baseDate),
            walkDistanceMeters: state.walkDist,
            transferCount: state.transfers,
          );
        }

        // 1. Board a trip from current stop
        final routes = _getRoutesFromStop(db, state.stopId, stopRouteMap);
        for (final route in routes) {
          if (!activeServices.contains(route.serviceId)) continue;

          final departure = _getNextDeparture(
            db,
            state.stopId,
            route.routeId,
            route.directionId,
            state.time,
          );
          if (departure == null) continue;

          final tripId = departure['trip_id'] as String;
          final stopsOnTrip = _getStopsOnTrip(db, tripId, departure['stop_sequence'] as int);
          
          for (final stopEntry in stopsOnTrip) {
            final nextStopId = stopEntry['stop_id'] as String;
            final arrTime = stopEntry['arrival_time_seconds'] as int;
            
            if (arrTime > deadlineSeconds) continue;

            final newPath = [...state.path, _PathSegment.trip(tripId, route.routeId, state.stopId, nextStopId)];
            final newTime = arrTime;
            final newTransfers = state.transfers;
            final newWalkDist = state.walkDist;

            final prev = best[nextStopId];
            if (prev == null || newTime < prev.time || (newTime == prev.time && newTransfers < prev.transfers)) {
              best[nextStopId] = _BestCost(newTime, newTransfers, newWalkDist);
              queue.add(_State(nextStopId, newTime, newPath, newTransfers, newWalkDist));
            }
          }
        }

        // 2. Walk to nearby stops
        final transfers = _getTransfersFromStop(db, state.stopId, transferMap);
        for (final t in transfers) {
          if (t.walkTimeSeconds > maxWalkMeters / 1.2) continue;
          
          final newTime = state.time + t.walkTimeSeconds;
          if (newTime > deadlineSeconds) continue;
          
          final nextStop = t.toStopId;
          final newTransfers = state.transfers + 1;
          if (newTransfers > maxTransfers) continue;
          
          final newWalkDist = state.walkDist + t.walkDistMeters;

          final prev = best[nextStop];
          if (prev == null || newTime < prev.time || (newTime == prev.time && newTransfers < prev.transfers)) {
            best[nextStop] = _BestCost(newTime, newTransfers, newWalkDist);
            final newPath = [...state.path, _PathSegment.walk(state.stopId, nextStop, t.walkDistMeters)];
            queue.add(_State(nextStop, newTime, newPath, newTransfers, newWalkDist));
          }
        }
      }
      return null;
    } finally {
      db.dispose();
    }
  }

  // -------------------------------------------------------------------------
  // Database queries 
  // -------------------------------------------------------------------------
  List<_RouteInfo> _getRoutesFromStop(
      sqlite3.Database db, String stopId, Map<String, List<_RouteInfo>> cache) {
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
    final list = rows
        .map((r) => _RouteInfo(
              routeId: r['route_id'] as String,
              directionId: r['direction_id'] as int,
              serviceId: r['service_id'] as String,
              stopSequence: r['first_sequence'] as int,
            ))
        .toList();
    cache[stopId] = list;
    return list;
  }

  Map<String, dynamic>? _getNextDeparture(
    sqlite3.Database db,
    String stopId,
    String routeId,
    int directionId,
    int afterSeconds,
  ) {
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
      'trip_id': rows.first['trip_id'] as String,
      'departure_time_seconds': rows.first['departure_time_seconds'] as int,
      'stop_sequence': rows.first['stop_sequence'] as int,
    };
  }

  List<Map<String, dynamic>> _getStopsOnTrip(
    sqlite3.Database db,
    String tripId,
    int afterSequence,
  ) {
    final rows = db.select(
      '''SELECT stop_id, arrival_time_seconds
         FROM stop_times
         WHERE trip_id = ? AND stop_sequence > ?
         ORDER BY stop_sequence''',
      [tripId, afterSequence],
    );
    return rows
        .map((r) => {
              'stop_id': r['stop_id'] as String,
              'arrival_time_seconds': r['arrival_time_seconds'] as int,
            })
        .toList();
  }

  List<_Transfer> _getTransfersFromStop(
      sqlite3.Database db, String stopId, Map<String, List<_Transfer>> cache) {
    if (cache.containsKey(stopId)) return cache[stopId]!;
    final rows = db.select(
      '''SELECT to_stop_id, min_transfer_time
         FROM transfers
         WHERE from_stop_id = ?''',
      [stopId],
    );
    final list = rows
        .map((r) => _Transfer(
              toStopId: r['to_stop_id'] as String,
              walkTimeSeconds: r['min_transfer_time'] as int,
              walkDistMeters: (r['min_transfer_time'] as int) * 1.2,
            ))
        .toList();
    cache[stopId] = list;
    return list;
  }

  // -------------------------------------------------------------------------
  // Build final route segments with shape polylines
  // -------------------------------------------------------------------------
  List<RouteSegment> _buildSegments(
      sqlite3.Database db, List<_PathSegment> path, int endTime, DateTime baseDate) {
    final segments = <RouteSegment>[];

    for (final p in path) {
      if (p.type == 'walk') {
        segments.add(RouteSegment(
          fromStopId: p.fromStop,
          toStopId: p.toStop,
          departureSeconds: 0,
          arrivalSeconds: 0,
          routeId: 'walk',
          tripId: 'walk',
          directionId: 0,
          geometryPolyline: null,
        ));
      } else if (p.type == 'trip') {
        String? polyline;
        final shapeRows = db.select(
          '''SELECT tg.encoded_polyline
             FROM trip_geometry tg
             JOIN trips t ON tg.shape_id = t.shape_id
             WHERE t.trip_id = ?''',
          [p.tripId!],
        );
        if (shapeRows.isNotEmpty) {
          polyline = shapeRows.first[0] as String?;
        }

        final stopTimesRows = db.select(
          '''SELECT stop_id, departure_time_seconds, arrival_time_seconds
             FROM stop_times
             WHERE trip_id = ? AND stop_id IN (?, ?)
             ORDER BY stop_sequence''',
          [p.tripId!, p.fromStop, p.toStop],
        );
        
        int depSec = 0, arrSec = 0;
        for (final r in stopTimesRows) {
          final sid = r['stop_id'] as String;
          final dep = r['departure_time_seconds'] as int;
          final arr = r['arrival_time_seconds'] as int;
          if (sid == p.fromStop) depSec = dep;
          if (sid == p.toStop) arrSec = arr;
        }

        segments.add(RouteSegment(
          fromStopId: p.fromStop,
          toStopId: p.toStop,
          departureSeconds: depSec,
          arrivalSeconds: arrSec,
          routeId: p.routeId ?? '',
          tripId: p.tripId ?? '',
          directionId: 0,
          geometryPolyline: polyline,
        ));
      }
    }
    return segments;
  }
}

// ---------------------------------------------------------------------------
// Internal helper classes
// ---------------------------------------------------------------------------
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
  final String type;
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
