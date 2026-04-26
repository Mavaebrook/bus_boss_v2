import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

// ---------------------------------------------------------------------------
// Constants from specification
// ---------------------------------------------------------------------------
const double walkSpeedMps = 1.2;
const int maxTransferRadiusM = 300;
const double latThreshold = 0.0027; // ~300m at Orlando latitude
const double lonThreshold = 0.0031;

// ---------------------------------------------------------------------------
// Helper: "HH:MM:SS" → seconds (overnight times >24:00 kept exactly)
// ---------------------------------------------------------------------------
int timeToSeconds(String s) {
  final parts = s.trim().split(':');
  return int.parse(parts[0]) * 3600 +
         int.parse(parts[1]) * 60 +
         int.parse(parts[2]);
}

// ---------------------------------------------------------------------------
// Streaming interpolation – matches JS algorithm line for line
// ---------------------------------------------------------------------------
void interpolateStopTimes(List<Map<String, dynamic>> stopRows) {
  // Pass 1 – convert known times to seconds
  for (final row in stopRows) {
    final arr = (row['arrival_time'] as String).trim();
    final dep = (row['departure_time'] as String).trim();
    row['arr_sec'] = arr.isNotEmpty ? timeToSeconds(arr) : null;
    row['dep_sec'] = dep.isNotEmpty
        ? timeToSeconds(dep)
        : row['arr_sec'] ?? null;
  }

  // Pass 2 – fill null segments
  int i = 0;
  while (i < stopRows.length) {
    if (stopRows[i]['arr_sec'] == null) {
      final left = i - 1;
      int right = i + 1;
      while (right < stopRows.length && stopRows[right]['arr_sec'] == null) {
        right++;
      }

      if (left < 0 && right >= stopRows.length) break;

      if (left < 0) {
        // Leading nulls
        int nextKnown = right + 1;
        while (nextKnown < stopRows.length &&
            stopRows[nextKnown]['arr_sec'] == null) {
          nextKnown++;
        }
        final interval = (nextKnown < stopRows.length)
            ? (stopRows[nextKnown]['arr_sec'] - stopRows[right]['arr_sec']) /
                (nextKnown - right)
            : 120;
        for (int k = i; k < right; k++) {
          final t =
              (stopRows[right]['arr_sec'] - ((right - k) * interval)).round();
          stopRows[k]['arr_sec'] = t;
          stopRows[k]['dep_sec'] = t;
        }
      } else if (right >= stopRows.length) {
        // Trailing nulls
        int prevKnown = left - 1;
        while (prevKnown >= 0 && stopRows[prevKnown]['arr_sec'] == null) {
          prevKnown--;
        }
        final interval = (prevKnown >= 0)
            ? (stopRows[left]['arr_sec'] - stopRows[prevKnown]['arr_sec']) /
                (left - prevKnown)
            : 120;
        for (int k = i; k < stopRows.length; k++) {
          final t =
              (stopRows[left]['arr_sec'] + ((k - left) * interval)).round();
          stopRows[k]['arr_sec'] = t;
          stopRows[k]['dep_sec'] = t;
        }
        break;
      } else {
        // Bracketed nulls
        final t0 = stopRows[left]['arr_sec'] as int;
        final t1 = stopRows[right]['arr_sec'] as int;
        final span = right - left;
        for (int k = i; k < right; k++) {
          final t = (t0 + ((k - left) / span) * (t1 - t0)).round();
          stopRows[k]['arr_sec'] = t;
          stopRows[k]['dep_sec'] = t;
        }
      }
      i = right;
    } else {
      i++;
    }
  }

  // Finalise back to seconds
  for (final row in stopRows) {
    row['arrival_time_seconds'] = (row['arr_sec'] as int?) ?? 0;
    row['departure_time_seconds'] = (row['dep_sec'] as int?) ?? 0;
  }
}

// ---------------------------------------------------------------------------
// Google Encoded Polyline
// ---------------------------------------------------------------------------
String encodePolyline(List<List<double>> points) {
  final buf = StringBuffer();
  int prevLat = 0, prevLng = 0;
  for (final p in points) {
    // Round to 5dp to kill IEEE 754 artifacts
    final lat = (p[0] * 1e5).round();
    final lng = (p[1] * 1e5).round();
    for (final val in [lat, lng]) {
      final prev = val == lat ? prevLat : prevLng;
      int diff = val - prev;
      int enc = diff < 0 ? ~(diff << 1) : (diff << 1);
      while (enc >= 0x20) {
        buf.writeCharCode((0x20 | (enc & 0x1f)) + 63);
        enc >>= 5;
      }
      buf.writeCharCode(enc + 63);
    }
    prevLat = lat;
    prevLng = lng;
  }
  return buf.toString();
}

// ---------------------------------------------------------------------------
// Haversine distance
// ---------------------------------------------------------------------------
double haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  const R = 6371000;
  final dLat = (lat2 - lat1) * pi / 180;
  final dLon = (lon2 - lon1) * pi / 180;
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1 * pi / 180) * cos(lat2 * pi / 180) *
          sin(dLon / 2) * sin(dLon / 2);
  return R * 2 * atan2(sqrt(a), sqrt(1 - a));
}

// ---------------------------------------------------------------------------
// Main ETL pipeline
// ---------------------------------------------------------------------------
Future<void> buildDatabase(String gtfsZipPath, String outputDbPath) async {
  if (File(outputDbPath).existsSync()) {
    File(outputDbPath).deleteSync();
  }

  final db = sqlite3.sqlite3.open(outputDbPath);
  db.execute("PRAGMA journal_mode=WAL");
  db.execute("PRAGMA synchronous=NORMAL");
  db.execute("PRAGMA foreign_keys=OFF");

  // Staging tables – exact same schema as production
  const stagingTables = <String, String>{
    'routes':   'CREATE TABLE _routes_staging (route_id TEXT PRIMARY KEY, route_short_name TEXT, route_long_name TEXT, route_type INTEGER)',
    'stops':    'CREATE TABLE _stops_staging (stop_id TEXT PRIMARY KEY, stop_name TEXT, stop_lat REAL, stop_lon REAL, location_type INTEGER, wheelchair_boarding INTEGER)',
    'trips':    'CREATE TABLE _trips_staging (trip_id TEXT PRIMARY KEY, route_id TEXT, service_id TEXT, direction_id INTEGER, shape_id TEXT)',
    'stop_times': 'CREATE TABLE _stop_times_staging (trip_id TEXT, stop_sequence INTEGER, stop_id TEXT, arrival_time_seconds INTEGER, departure_time_seconds INTEGER, PRIMARY KEY(trip_id, stop_sequence))',
    'calendar': 'CREATE TABLE _calendar_staging (service_id TEXT PRIMARY KEY, monday INTEGER, tuesday INTEGER, wednesday INTEGER, thursday INTEGER, friday INTEGER, saturday INTEGER, sunday INTEGER, start_date INTEGER, end_date INTEGER)',
    'calendar_dates': 'CREATE TABLE _calendar_dates_staging (service_id TEXT, date INTEGER, exception_type INTEGER, PRIMARY KEY(service_id, date))',
    'trip_geometry': 'CREATE TABLE _trip_geometry_staging (shape_id TEXT PRIMARY KEY, encoded_polyline TEXT NOT NULL)',
    'transfers': 'CREATE TABLE _transfers_staging (from_stop_id TEXT, to_stop_id TEXT, transfer_type INTEGER, min_transfer_time INTEGER, PRIMARY KEY(from_stop_id, to_stop_id))',
    'stop_route_map': 'CREATE TABLE _stop_route_map_staging (stop_id TEXT, route_id TEXT, direction_id INTEGER, PRIMARY KEY(stop_id, route_id, direction_id))',
    'active_services': 'CREATE TABLE _active_services_staging (service_date INTEGER, service_id TEXT, PRIMARY KEY(service_date, service_id))',
    'source_file_versions': 'CREATE TABLE _source_file_versions_staging (file_name TEXT PRIMARY KEY, checksum TEXT NOT NULL, last_loaded INTEGER NOT NULL, layer TEXT NOT NULL)',
    'service_runtime_state': 'CREATE TABLE _service_runtime_state_staging (state_key TEXT PRIMARY KEY, feed_valid INTEGER NOT NULL, last_successful_sync INTEGER, next_refresh_at INTEGER, stale_reason TEXT, active_services_generated_at INTEGER)',
    'feed_metadata': 'CREATE TABLE _feed_metadata_staging (feed_id TEXT PRIMARY KEY, schema_version INTEGER NOT NULL, generated_at INTEGER NOT NULL, valid_from INTEGER NOT NULL, valid_to INTEGER NOT NULL)',
  };

  for (final sql in stagingTables.values) {
    db.execute(sql);
  }

  final unixNow = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final stops = <Map<String, dynamic>>[];

  // ---------- Parse GTFS zip ----------
  final zipBytes = File(gtfsZipPath).readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(zipBytes);

  for (final file in archive) {
    final bytes = file.content as List<int>;
    final lines = const Utf8Decoder().convert(bytes).split('\n');
    final rows = lines.skip(1).where((l) => l.trim().isNotEmpty);

    switch (file.name) {
      case 'routes.txt':
        for (final row in rows) {
          final vals = row.split(',');
          db.execute(
            'INSERT INTO _routes_staging VALUES (?,?,?,?)',
            [vals[0].trim(), vals[1].trim(), vals[2].trim(), int.parse(vals[3].trim())],
          );
        }
        break;

      case 'stops.txt':
        for (final row in rows) {
          final vals = row.split(',');
          final stop = {
            'stop_id': vals[0].trim(),
            'stop_name': vals[1].trim(),
            'stop_lat': double.parse(vals[2].trim()),
            'stop_lon': double.parse(vals[3].trim()),
            'location_type': int.tryParse(vals[4].trim()) ?? 0,
            'wheelchair_boarding': int.tryParse(vals[5].trim()) ?? 0,
          };
          stops.add(stop);
          db.execute(
            'INSERT INTO _stops_staging VALUES (?,?,?,?,?,?)',
            [stop['stop_id'], stop['stop_name'], stop['stop_lat'],
             stop['stop_lon'], stop['location_type'], stop['wheelchair_boarding']],
          );
        }
        break;

      case 'shapes.txt':
        final shapes = <String, List<Map<String, dynamic>>>{};
        for (final row in rows) {
          final vals = row.split(',');
          final shapeId = vals[0].trim();
          shapes.putIfAbsent(shapeId, () => []);
          shapes[shapeId]!.add({
            'lat': double.parse(vals[1].trim()),
            'lon': double.parse(vals[2].trim()),
            'seq': int.parse(vals[3].trim()),
          });
        }
        for (final entry in shapes.entries) {
          final points = entry.value
            ..sort((a, b) => (a['seq'] as int).compareTo(b['seq'] as int));
          final poly = encodePolyline(
            points.map((p) => [p['lat'] as double, p['lon'] as double]).toList(),
          );
          db.execute(
            'INSERT INTO _trip_geometry_staging VALUES (?,?)',
            [entry.key, poly],
          );
        }
        break;

      case 'calendar.txt':
        for (final row in rows) {
          final vals = row.split(',');
          db.execute(
            'INSERT INTO _calendar_staging VALUES (?,?,?,?,?,?,?,?,?,?)',
            [
              vals[0].trim(),
              int.parse(vals[1].trim()),
              int.parse(vals[2].trim()),
              int.parse(vals[3].trim()),
              int.parse(vals[4].trim()),
              int.parse(vals[5].trim()),
              int.parse(vals[6].trim()),
              int.parse(vals[7].trim()),
              int.parse(vals[8].trim()),
              int.parse(vals[9].trim()),
            ],
          );
        }
        break;

      case 'calendar_dates.txt':
        for (final row in rows) {
          final vals = row.split(',');
          db.execute(
            'INSERT INTO _calendar_dates_staging VALUES (?,?,?)',
            [vals[0].trim(), int.parse(vals[1].trim()), int.parse(vals[2].trim())],
          );
        }
        break;

      case 'trips.txt':
        for (final row in rows) {
          final vals = row.split(',');
          db.execute(
            'INSERT INTO _trips_staging VALUES (?,?,?,?,?)',
            [
              vals[0].trim(),
              vals[1].trim(),
              vals[2].trim(),
              int.parse(vals[3].trim()),
              vals[4].trim(),
            ],
          );
        }
        break;

      case 'stop_times.txt':
        // Stream by trip_id
        var currentTrip = '';
        var tripBuffer = <Map<String, dynamic>>[];
        for (final row in rows) {
          final vals = row.split(',');
          final tripId = vals[0].trim();
          if (currentTrip.isEmpty) currentTrip = tripId;
          if (tripId != currentTrip) {
            interpolateStopTimes(tripBuffer);
            for (final st in tripBuffer) {
              db.execute(
                'INSERT INTO _stop_times_staging VALUES (?,?,?,?,?)',
                [
                  st['trip_id'],
                  st['stop_sequence'],
                  st['stop_id'],
                  st['arrival_time_seconds'],
                  st['departure_time_seconds'],
                ],
              );
            }
            tripBuffer = [];
            currentTrip = tripId;
          }
          tripBuffer.add({
            'trip_id': tripId,
            'stop_sequence': int.parse(vals[1].trim()),
            'stop_id': vals[2].trim(),
            'arrival_time': vals[3].trim(),
            'departure_time': vals[4].trim(),
          });
        }
        // Last trip
        if (tripBuffer.isNotEmpty) {
          interpolateStopTimes(tripBuffer);
          for (final st in tripBuffer) {
            db.execute(
              'INSERT INTO _stop_times_staging VALUES (?,?,?,?,?)',
              [
                st['trip_id'],
                st['stop_sequence'],
                st['stop_id'],
                st['arrival_time_seconds'],
                st['departure_time_seconds'],
              ],
            );
          }
        }
        break;

      default:
        break;
    }
  }

  // ---------- Generate transfers ----------
  final transferStmt = db.prepare(
    'INSERT INTO _transfers_staging VALUES (?,?,?,?)',
  );
  for (final s1 in stops) {
    for (final s2 in stops) {
      if (s1['stop_id'] == s2['stop_id']) continue;
      final lat1 = s1['stop_lat'] as double;
      final lon1 = s1['stop_lon'] as double;
      final lat2 = s2['stop_lat'] as double;
      final lon2 = s2['stop_lon'] as double;
      if ((lat1 - lat2).abs() > latThreshold) continue;
      if ((lon1 - lon2).abs() > lonThreshold) continue;
      final dist = haversineMeters(lat1, lon1, lat2, lon2);
      if (dist <= maxTransferRadiusM) {
        transferStmt.execute([
          s1['stop_id'],
          s2['stop_id'],
          2,
          (dist / walkSpeedMps).round(),
        ]);
      }
    }
  }
  transferStmt.dispose();

  // ---------- Materialize stop_route_map ----------
  db.execute('''
    INSERT INTO _stop_route_map_staging
    SELECT DISTINCT st.stop_id, t.route_id, t.direction_id
    FROM _stop_times_staging st
    JOIN _trips_staging t ON st.trip_id = t.trip_id
  ''');

  // ---------- Materialize active_services ----------
  final calRes = db.select('SELECT * FROM _calendar_staging');
  final services = <int, Set<String>>{};
  for (final row in calRes) {
    final svcId = row.columnAt(0) as String;
    final flags = [
      row.columnAt(1), row.columnAt(2), row.columnAt(3), row.columnAt(4),
      row.columnAt(5), row.columnAt(6), row.columnAt(7),
    ];
    final start = row.columnAt(8) as int;
    final end = row.columnAt(9) as int;

    var d = DateTime.parse(
        '${start.toString().substring(0,4)}-${start.toString().substring(4,6)}-${start.toString().substring(6,8)}');
    final endDate = DateTime.parse(
        '${end.toString().substring(0,4)}-${end.toString().substring(4,6)}-${end.toString().substring(6,8)}');

    while (!d.isAfter(endDate)) {
      final dateInt = int.parse(
        '${d.year}${d.month.toString().padLeft(2,'0')}${d.day.toString().padLeft(2,'0')}',
      );
      if ((flags[d.weekday % 7] as int) == 1) {
        services.putIfAbsent(dateInt, () => {}).add(svcId);
      }
      d = d.add(const Duration(days: 1));
    }
  }

  // Apply calendar_dates overrides
  final cdRes = db.select(
      'SELECT service_id, date, exception_type FROM _calendar_dates_staging');
  for (final row in cdRes) {
    final svcId = row.columnAt(0) as String;
    final date = row.columnAt(1) as int;
    final type = row.columnAt(2) as int;
    if (type == 1) {
      services.putIfAbsent(date, () => {}).add(svcId);
    } else if (type == 2) {
      services[date]?.remove(svcId);
    }
  }

  final activeInsert = db.prepare('INSERT INTO _active_services_staging VALUES (?,?)');
  for (final entry in services.entries) {
    for (final svc in entry.value) {
      activeInsert.execute([entry.key, svc]);
    }
  }
  activeInsert.dispose();

  // ---------- Create indexes ----------
  const indexes = [
    'CREATE INDEX idx_routes_short_name ON _routes_staging(route_short_name)',
    'CREATE INDEX idx_trips_route ON _trips_staging(route_id)',
    'CREATE INDEX idx_trips_service ON _trips_staging(service_id, route_id)',
    'CREATE INDEX idx_trips_shape ON _trips_staging(shape_id)',
    'CREATE INDEX idx_st_arrival_backwards ON _stop_times_staging(stop_id, arrival_time_seconds DESC)',
    'CREATE INDEX idx_st_departure ON _stop_times_staging(stop_id, departure_time_seconds)',
    'CREATE INDEX idx_st_trip ON _stop_times_staging(trip_id, stop_sequence)',
    'CREATE INDEX idx_stops_spatial ON _stops_staging(stop_lat, stop_lon)',
    'CREATE INDEX idx_calendar_range ON _calendar_staging(start_date, end_date)',
    'CREATE INDEX idx_transfers_from ON _transfers_staging(from_stop_id, min_transfer_time)',
    'CREATE INDEX idx_srm_directional ON _stop_route_map_staging(stop_id, direction_id, route_id)',
    'CREATE INDEX idx_active_services_date ON _active_services_staging(service_date)',
  ];
  for (final sql in indexes) {
    db.execute(sql);
  }

  // ---------- ANALYZE ----------
  db.execute('ANALYZE');

  // ---------- Atomic swap ----------
  db.execute('BEGIN');
  for (final table in stagingTables.keys) {
    db.execute('DROP TABLE IF EXISTS $table');
    db.execute('ALTER TABLE _$table\_staging RENAME TO $table');
  }
  db.execute('COMMIT');

  // ---------- Operational rows ----------
  final calBounds = db.select('SELECT MIN(start_date), MAX(end_date) FROM calendar');
  final from = calBounds.first.columnAt(0) as int;
  final to = calBounds.first.columnAt(1) as int;

  db.execute(
    'INSERT INTO feed_metadata VALUES (?,?,?,?,?)',
    ['lynx', 1, unixNow, from, to],
  );

  for (final fname in ['routes.txt','stops.txt','shapes.txt','trips.txt',
                        'stop_times.txt','calendar.txt','calendar_dates.txt']) {
    final layer = (fname == 'routes.txt' || fname == 'stops.txt' || fname == 'shapes.txt')
        ? 'static'
        : 'volatile';
    db.execute(
      'INSERT INTO source_file_versions VALUES (?,?,?,?)',
      [fname, 'hash_not_used_yet', unixNow, layer],
    );
  }

  db.execute(
    'INSERT INTO service_runtime_state VALUES (?,?,?,?,?,?)',
    ['primary', 1, unixNow, unixNow + 7 * 86400, null, unixNow],
  );

  // ---------- Finalise ----------
  db.execute('COMMIT'); // close any pending txn
  db.execute('VACUUM');
  db.dispose();
  print('ETL complete → $outputDbPath');
}
