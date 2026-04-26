import 'dart:io';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:contracts/contracts.dart';

class TransitQueryEngine {
  final String dbPath;

  TransitQueryEngine({required this.dbPath});

  /// Returns all service IDs active on a given date (YYYYMMDD int).
  List<String> getActiveServiceIds(int date) {
    final db = sqlite3.sqlite3.open(dbPath);
    final rows = db.select(
      'SELECT service_id FROM active_services WHERE service_date = ?',
      [date],
    );
    db.dispose();
    return rows.map((r) => r.columnAt(0) as String).toList();
  }

  /// Snap a location to the nearest trip/stop.
  /// Returns a map with stop_id, trip_id, shape_id, or null.
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

  /// Full trip plan – placeholder for now.
  TripPlan? getTripPlan(
      String fromStopId, String toStopId, DateTime deadline) {
    // TODO: implement pathfinding using stop_times, transfers, active_services
    return null;
  }
}
