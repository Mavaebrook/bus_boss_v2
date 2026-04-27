#!/usr/bin/env python3
"""
LYNX GTFS ETL Pipeline
Implements the exact schema, parsing rules, interpolation, shape compilation,
transfer generation, and atomic swap described in the database strategy.
Outputs a single SQLite database ready for the TransitQueryEngine.
"""

import sqlite3
import csv
import zipfile
import math
import sys
import os
import io
from datetime import datetime, timezone, timedelta, date

# ----------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------
WALK_SPEED_MPS = 1.2
MAX_TRANSFER_RADIUS_M = 300
LAT_THRESHOLD = 0.0027   # ~300m at 28°N
LON_THRESHOLD = 0.0031

UNIX_NOW = int(datetime.now(timezone.utc).timestamp())

def time_to_seconds(time_str: str) -> int:
    """Convert HH:MM:SS to seconds; values >24:00 kept as-is."""
    if not time_str: return None
    parts = time_str.strip().split(':')
    h, m, s = map(int, parts)
    return h * 3600 + m * 60 + s

def interpolate_stop_times(stop_rows):
    """Linear interpolation for missing GTFS arrival/departure times."""
    for row in stop_rows:
        arr = row.get('arrival_time', '').strip()
        row['arr_sec'] = time_to_seconds(arr)
        row['dep_sec'] = row['arr_sec'] # Simplification for LYNX interpolation

    n = len(stop_rows)
    if n == 0: return stop_rows

    # Find first and last known indices
    known_indices = [i for i, r in enumerate(stop_rows) if r['arr_sec'] is not None]
    
    if not known_indices:
        return stop_rows # No data to interpolate

    # 1. Fill Leading Nulls
    first_idx = known_indices[0]
    if first_idx > 0:
        # If we only have one known point, we use a default 120s offset
        interval = 120 
        if len(known_indices) > 1:
            interval = (stop_rows[known_indices[1]]['arr_sec'] - stop_rows[first_idx]['arr_sec']) / (known_indices[1] - first_idx)
        
        for k in range(first_idx - 1, -1, -1):
            stop_rows[k]['arr_sec'] = stop_rows[k+1]['arr_sec'] - interval

    # 2. Fill Trailing Nulls
    last_idx = known_indices[-1]
    if last_idx < n - 1:
        interval = 120
        if len(known_indices) > 1:
            interval = (stop_rows[last_idx]['arr_sec'] - stop_rows[known_indices[-2]]['arr_sec']) / (last_idx - known_indices[-2])
        
        for k in range(last_idx + 1, n):
            stop_rows[k]['arr_sec'] = stop_rows[k-1]['arr_sec'] + interval

    # 3. Fill Bracketed (Middle) Nulls
    for i in range(len(known_indices) - 1):
        left = known_indices[i]
        right = known_indices[i+1]
        if right - left > 1:
            t0, t1 = stop_rows[left]['arr_sec'], stop_rows[right]['arr_sec']
            step = (t1 - t0) / (right - left)
            for k in range(left + 1, right):
                stop_rows[k]['arr_sec'] = t0 + (step * (k - left))

    for row in stop_rows:
        row['arrival_time_seconds'] = int(round(row['arr_sec']))
        row['departure_time_seconds'] = int(round(row['arr_sec']))
    return stop_rows

def encode_polyline(points):
    """Google Encoded Polyline algorithm."""
    result = []
    prev_lat, prev_lng = 0, 0
    for lat, lng in points:
        lat, lng = round(lat, 5), round(lng, 5)
        for val, prev in [(lat, prev_lat), (lng, prev_lng)]:
            cur = round(val * 1e5)
            diff = cur - prev
            cur_enc = ~(diff << 1) if diff < 0 else (diff << 1)
            while cur_enc >= 0x20:
                result.append(chr((0x20 | (cur_enc & 0x1f)) + 63))
                cur_enc >>= 5
            result.append(chr(cur_enc + 63))
            if val == lat: prev_lat = cur
            else: prev_lng = cur
    return ''.join(result)

def haversine_meters(lat1, lon1, lat2, lon2):
    R = 6371000
    dlat, dlon = math.radians(lat2 - lat1), math.radians(lon2 - lon1)
    a = math.sin(dlat/2)**2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlon/2)**2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))

def generate_transfers(cursor, stops):
    transfers = []
    for i, s1 in enumerate(stops):
        for s2 in stops[i+1:]:
            if abs(s1['stop_lat'] - s2['stop_lat']) > LAT_THRESHOLD or abs(s1['stop_lon'] - s2['stop_lon']) > LON_THRESHOLD:
                continue
            dist = haversine_meters(s1['stop_lat'], s1['stop_lon'], s2['stop_lat'], s2['stop_lon'])
            if dist <= MAX_TRANSFER_RADIUS_M:
                weight = round(dist / WALK_SPEED_MPS)
                transfers.append((s1['stop_id'], s2['stop_id'], 2, weight))
                transfers.append((s2['stop_id'], s1['stop_id'], 2, weight))
    cursor.executemany("INSERT INTO _transfers_staging VALUES (?,?,?,?)", transfers)

def run_etl(gtfs_zip_path, db_path):
    if os.path.exists(db_path):
        os.remove(db_path)

    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=WAL")
    cur = conn.cursor()

    tables_sql = {
        "routes": "route_id TEXT PRIMARY KEY, route_short_name TEXT, route_long_name TEXT, route_type INTEGER",
        "stops": "stop_id TEXT PRIMARY KEY, stop_name TEXT, stop_lat REAL, stop_lon REAL, location_type INTEGER, wheelchair_boarding INTEGER",
        "trips": "trip_id TEXT PRIMARY KEY, route_id TEXT, service_id TEXT, direction_id INTEGER, shape_id TEXT",
        "stop_times": "trip_id TEXT, stop_sequence INTEGER, stop_id TEXT, arrival_time_seconds INTEGER, departure_time_seconds INTEGER, PRIMARY KEY (trip_id, stop_sequence)",
        "calendar": "service_id TEXT PRIMARY KEY, monday INTEGER, tuesday INTEGER, wednesday INTEGER, thursday INTEGER, friday INTEGER, saturday INTEGER, sunday INTEGER, start_date INTEGER, end_date INTEGER",
        "calendar_dates": "service_id TEXT, date INTEGER, exception_type INTEGER, PRIMARY KEY (service_id, date)",
        "trip_geometry": "shape_id TEXT PRIMARY KEY, encoded_polyline TEXT NOT NULL",
        "transfers": "from_stop_id TEXT, to_stop_id TEXT, transfer_type INTEGER, min_transfer_time INTEGER, PRIMARY KEY (from_stop_id, to_stop_id)",
        "stop_route_map": "stop_id TEXT, route_id TEXT, direction_id INTEGER, PRIMARY KEY (stop_id, route_id, direction_id)",
        "active_services": "service_date INTEGER, service_id TEXT, PRIMARY KEY (service_date, service_id)",
        "source_file_versions": "file_name TEXT PRIMARY KEY, checksum TEXT NOT NULL, last_loaded INTEGER NOT NULL, layer TEXT NOT NULL",
        "service_runtime_state": "state_key TEXT PRIMARY KEY, feed_valid INTEGER NOT NULL, last_successful_sync INTEGER, next_refresh_at INTEGER, stale_reason TEXT, active_services_generated_at INTEGER",
        "feed_metadata": "feed_id TEXT PRIMARY KEY, schema_version INTEGER NOT NULL, generated_at INTEGER NOT NULL, valid_from INTEGER NOT NULL, valid_to INTEGER NOT NULL"
    }

    for tbl, schema in tables_sql.items():
        cur.execute(f"CREATE TABLE _{tbl}_staging ({schema})")

    with zipfile.ZipFile(gtfs_zip_path, 'r') as zf:
        # Load routes
        with zf.open('routes.txt') as f:
            reader = csv.DictReader(io.TextIOWrapper(f, 'utf-8'))
            cur.executemany("INSERT INTO _routes_staging VALUES (?,?,?,?)", 
                [(r['route_id'].strip(), r['route_short_name'].strip(), r['route_long_name'].strip(), int(r['route_type'])) for r in reader])

        # Load stops
        stops = []
        with zf.open('stops.txt') as f:
            reader = csv.DictReader(io.TextIOWrapper(f, 'utf-8'))
            for r in reader:
                s = (r['stop_id'].strip(), r['stop_name'].strip(), float(r['stop_lat']), float(r['stop_lon']), 
                     int(r.get('location_type', 0)), int(r.get('wheelchair_boarding', 0)))
                stops.append({'stop_id': s[0], 'stop_lat': s[2], 'stop_lon': s[3]})
                cur.execute("INSERT INTO _stops_staging VALUES (?,?,?,?,?,?)", s)

        # Load shapes
        shapes = {}
        with zf.open('shapes.txt') as f:
            reader = csv.DictReader(io.TextIOWrapper(f, 'utf-8'))
            for r in reader:
                shapes.setdefault(r['shape_id'].strip(), []).append((int(r['shape_pt_sequence']), float(r['shape_pt_lat']), float(r['shape_pt_lon'])))
        for sid, pts in shapes.items():
            pts.sort()
            cur.execute("INSERT INTO _trip_geometry_staging VALUES (?,?)", (sid, encode_polyline([(p[1], p[2]) for p in pts])))

        # Load calendar & dates
        with zf.open('calendar.txt') as f:
            reader = csv.DictReader(io.TextIOWrapper(f, 'utf-8'))
            cur.executemany("INSERT INTO _calendar_staging VALUES (?,?,?,?,?,?,?,?,?,?)", 
                [(r['service_id'].strip(), int(r['monday']), int(r['tuesday']), int(r['wednesday']), int(r['thursday']), int(r['friday']), int(r['saturday']), int(r['sunday']), int(r['start_date']), int(r['end_date'])) for r in reader])
        
        with zf.open('calendar_dates.txt') as f:
            reader = csv.DictReader(io.TextIOWrapper(f, 'utf-8'))
            cur.executemany("INSERT INTO _calendar_dates_staging VALUES (?,?,?)", [(r['service_id'].strip(), int(r['date']), int(r['exception_type'])) for r in reader])

        # Load trips
        with zf.open('trips.txt') as f:
            reader = csv.DictReader(io.TextIOWrapper(f, 'utf-8'))
            cur.executemany("INSERT INTO _trips_staging VALUES (?,?,?,?,?)", 
                [(r['trip_id'].strip(), r['route_id'].strip(), r['service_id'].strip(), int(r['direction_id']), r['shape_id'].strip()) for r in reader])

        # Load stop_times with interpolation
        with zf.open('stop_times.txt') as f:
            reader = csv.DictReader(io.TextIOWrapper(f, 'utf-8'))
            buffer, curr = [], None
            for r in reader:
                tid = r['trip_id'].strip()
                if curr and tid != curr:
                    for row in interpolate_stop_times(buffer):
                        cur.execute("INSERT INTO _stop_times_staging VALUES (?,?,?,?,?)", (row['trip_id'], row['stop_sequence'], row['stop_id'], row['arrival_time_seconds'], row['departure_time_seconds']))
                    buffer = []
                curr = tid
                buffer.append({'trip_id': tid, 'stop_sequence': int(r['stop_sequence']), 'stop_id': r['stop_id'].strip(), 'arrival_time': r['arrival_time'].strip()})
            if buffer:
                for row in interpolate_stop_times(buffer):
                    cur.execute("INSERT INTO _stop_times_staging VALUES (?,?,?,?,?)", (row['trip_id'], row['stop_sequence'], row['stop_id'], row['arrival_time_seconds'], row['departure_time_seconds']))

    generate_transfers(cur, stops)

    # Materialize stop_route_map
    cur.execute("INSERT INTO _stop_route_map_staging SELECT DISTINCT st.stop_id, t.route_id, t.direction_id FROM _stop_times_staging st JOIN _trips_staging t ON st.trip_id = t.trip_id")

    # Expand active_services
    cur.execute("SELECT * FROM _calendar_staging")
    for row in cur.fetchall():
        s_id, days, start, end = row[0], row[1:8], row[8], row[9]
        d = date(start//10000, (start//100)%100, start%100)
        e_d = date(end//10000, (end//100)%100, end%100)
        while d <= e_d:
            if days[d.weekday()]:
                cur.execute("INSERT OR IGNORE INTO _active_services_staging VALUES (?,?)", (d.year*10000 + d.month*100 + d.day, s_id))
            d += timedelta(days=1)
    cur.execute("SELECT service_id, date, exception_type FROM _calendar_dates_staging")
    for s_id, d, ex in cur.fetchall():
        if ex == 1: cur.execute("INSERT OR IGNORE INTO _active_services_staging VALUES (?,?)", (d, s_id))
        else: cur.execute("DELETE FROM _active_services_staging WHERE service_date=? AND service_id=?", (d, s_id))

    # Swap and Metadata
    cur.execute("BEGIN")
    for tbl in tables_sql.keys():
        cur.execute(f"ALTER TABLE _{tbl}_staging RENAME TO {tbl}")
    cur.execute("COMMIT")

    cur.execute("SELECT MIN(start_date), MAX(end_date) FROM calendar")
    min_d, max_d = cur.fetchone()
    cur.execute("INSERT INTO feed_metadata VALUES ('lynx', 1, ?, ?, ?)", (UNIX_NOW, min_d, max_d))
    cur.execute("INSERT INTO service_runtime_state VALUES ('primary', 1, ?, ?, NULL, ?)", (UNIX_NOW, UNIX_NOW + 604800, UNIX_NOW))
    
    conn.commit()
    conn.execute("VACUUM")
    conn.close()

if __name__ == '__main__':
    if len(sys.argv) == 3: run_etl(sys.argv[1], sys.argv[2])
      
