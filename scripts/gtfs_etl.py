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
import hashlib
import sys
import os
import io            # ← ADDED
from datetime import datetime, timezone

# ----------------------------------------------------------------------
# Constants from the JSX specification
# ----------------------------------------------------------------------
WALK_SPEED_MPS = 1.2
MAX_TRANSFER_RADIUS_M = 300
LAT_THRESHOLD = 0.0027   # ~300m at 28°N
LON_THRESHOLD = 0.0031

DB_PATH = None            # set from cli args
UNIX_NOW = int(datetime.now(timezone.utc).timestamp())

# ----------------------------------------------------------------------
# Helper: time string → seconds since midnight (supports >24:00)
# ----------------------------------------------------------------------
def time_to_seconds(time_str: str) -> int:
    """Convert HH:MM:SS to seconds; values >24:00 kept as-is."""
    parts = time_str.strip().split(':')
    h, m, s = map(int, parts)
    return h * 3600 + m * 60 + s

# ----------------------------------------------------------------------
# Interpolation algorithm (streaming, per-trip)
# ----------------------------------------------------------------------
def interpolate_stop_times(stop_rows):
    """Given a list of dicts for one trip, fill null arrival/departure in-place.
    
    Logic matches the JavaScript `interpolateStopTimes` from the spec:
    - Leading nulls → derive from first known segment of THIS trip
    - Trailing nulls → derive from last known segment of THIS trip
    - Bracketed nulls → linear interpolation
    """
    # Pass 1: convert known times to seconds
    for row in stop_rows:
        arr = row.get('arrival_time', '').strip()
        dep = row.get('departure_time', '').strip()
        row['arr_sec'] = time_to_seconds(arr) if arr else None
        row['dep_sec'] = time_to_seconds(dep) if dep else (
            row['arr_sec'] if row['arr_sec'] is not None else None
        )

    # Pass 2: fill null segments
    i = 0
    while i < len(stop_rows):
        if stop_rows[i]['arr_sec'] is None:
            left = i - 1
            right = i + 1
            while right < len(stop_rows) and stop_rows[right]['arr_sec'] is None:
                right += 1

            if left < 0 and right >= len(stop_rows):
                # No timing data at all – skip (should not happen in LYNX)
                break

            if left < 0:
                # Leading nulls: find next known segment of this trip
                next_known = right + 1
                while next_known < len(stop_rows) and stop_rows[next_known]['arr_sec'] is None:
                    next_known += 1
                interval = ((stop_rows[next_known]['arr_sec'] - stop_rows[right]['arr_sec']) /
                            (next_known - right)) if next_known < len(stop_rows) else 120
                for k in range(i, right):
                    t = round(stop_rows[right]['arr_sec'] - ((right - k) * interval))
                    stop_rows[k]['arr_sec'] = t
                    stop_rows[k]['dep_sec'] = t

            elif right >= len(stop_rows):
                # Trailing nulls: use last known segment
                prev_known = left - 1
                while prev_known >= 0 and stop_rows[prev_known]['arr_sec'] is None:
                    prev_known -= 1
                interval = ((stop_rows[left]['arr_sec'] - stop_rows[prev_known]['arr_sec']) /
                            (left - prev_known)) if prev_known >= 0 else 120
                for k in range(i, len(stop_rows)):
                    t = round(stop_rows[left]['arr_sec'] + ((k - left) * interval))
                    stop_rows[k]['arr_sec'] = t
                    stop_rows[k]['dep_sec'] = t
                break

            else:
                # Standard bracket
                t0, t1 = stop_rows[left]['arr_sec'], stop_rows[right]['arr_sec']
                span = right - left
                for k in range(i, right):
                    t = round(t0 + ((k - left) / span) * (t1 - t0))
                    stop_rows[k]['arr_sec'] = t
                    stop_rows[k]['dep_sec'] = t
            i = right
        else:
            i += 1

    # Convert back to integer seconds for storage
    for row in stop_rows:
        row['arrival_time_seconds'] = int(row['arr_sec']) if row['arr_sec'] is not None else None
        row['departure_time_seconds'] = int(row['dep_sec']) if row['dep_sec'] is not None else None

    return stop_rows

# ----------------------------------------------------------------------
# Polyline encoder (Google Encoded Polyline)
# ----------------------------------------------------------------------
def encode_polyline(points):
    """Encode list of (lat, lon) to polyline string. Same as JS version."""
    result = []
    prev_lat, prev_lng = 0, 0
    for lat, lng in points:
        # Round to 5 decimal places to kill IEEE 754 artifacts
        lat = round(lat, 5)
        lng = round(lng, 5)
        # encode latitudes
        for val, prev in [(lat, prev_lat), (lng, prev_lng)]:
            cur = round(val * 1e5)
            diff = cur - prev
            cur_enc = ~(diff << 1) if diff < 0 else (diff << 1)
            while cur_enc >= 0x20:
                result.append(chr((0x20 | (cur_enc & 0x1f)) + 63))
                cur_enc >>= 5
            result.append(chr(cur_enc + 63))
            if val == lat:
                prev_lat = cur
            else:
                prev_lng = cur
    return ''.join(result)

# ----------------------------------------------------------------------
# Transfer generation (bounding box + Haversine)
# ----------------------------------------------------------------------
def haversine_meters(lat1, lon1, lat2, lon2):
    R = 6371000
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = math.sin(dlat/2)**2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlon/2)**2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))

def generate_transfers(cursor, stops):
    """Create transfers table in the staging database."""
    transfers = []
    for i, s1 in enumerate(stops):
        lat1, lon1 = s1['stop_lat'], s1['stop_lon']
        for s2 in stops:
            if s1['stop_id'] == s2['stop_id']:
                continue
            # Bounding box pre-filter
            if abs(lat1 - s2['stop_lat']) > LAT_THRESHOLD:
                continue
            if abs(lon1 - s2['stop_lon']) > LON_THRESHOLD:
                continue
            dist = haversine_meters(lat1, lon1, s2['stop_lat'], s2['stop_lon'])
            if dist <= MAX_TRANSFER_RADIUS_M:
                transfers.append((
                    s1['stop_id'],
                    s2['stop_id'],
                    2,
                    round(dist / WALK_SPEED_MPS)
                ))
    cursor.executemany("INSERT INTO _transfers_staging VALUES (?,?,?,?)", transfers)
    print(f"Generated {len(transfers)} walking transfers.")

# ----------------------------------------------------------------------
# Main ETL pipeline
# ----------------------------------------------------------------------
def run_etl(gtfs_zip_path, db_path):
    global DB_PATH
    DB_PATH = db_path

    # Clean start or incremental? We'll rebuild from scratch each time for CI.
    # If you want incremental, you'd check existing db and compare checksums.
    # Here we always start fresh.
    if os.path.exists(DB_PATH):
        os.remove(DB_PATH)

    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA foreign_keys=OFF")   # speed; re-enable after swap
    cur = conn.cursor()

    # ------------------------------------------------------------------
    # Create staging tables identical to production schema
    # ------------------------------------------------------------------
    staging_prefix = "_staging"
    tables_sql = {
        "routes": """
            CREATE TABLE _routes_staging (
                route_id TEXT PRIMARY KEY,
                route_short_name TEXT,
                route_long_name TEXT,
                route_type INTEGER
            )""",
        "stops": """
            CREATE TABLE _stops_staging (
                stop_id TEXT PRIMARY KEY,
                stop_name TEXT,
                stop_lat REAL,
                stop_lon REAL,
                location_type INTEGER,
                wheelchair_boarding INTEGER
            )""",
        "trips": """
            CREATE TABLE _trips_staging (
                trip_id TEXT PRIMARY KEY,
                route_id TEXT,
                service_id TEXT,
                direction_id INTEGER,
                shape_id TEXT
            )""",
        "stop_times": """
            CREATE TABLE _stop_times_staging (
                trip_id TEXT,
                stop_sequence INTEGER,
                stop_id TEXT,
                arrival_time_seconds INTEGER,
                departure_time_seconds INTEGER,
                PRIMARY KEY (trip_id, stop_sequence)
            )""",
        "calendar": """
            CREATE TABLE _calendar_staging (
                service_id TEXT PRIMARY KEY,
                monday INTEGER,
                tuesday INTEGER,
                wednesday INTEGER,
                thursday INTEGER,
                friday INTEGER,
                saturday INTEGER,
                sunday INTEGER,
                start_date INTEGER,
                end_date INTEGER
            )""",
        "calendar_dates": """
            CREATE TABLE _calendar_dates_staging (
                service_id TEXT,
                date INTEGER,
                exception_type INTEGER,
                PRIMARY KEY (service_id, date)
            )""",
        "trip_geometry": """
            CREATE TABLE _trip_geometry_staging (
                shape_id TEXT PRIMARY KEY,
                encoded_polyline TEXT NOT NULL
            )""",
        "transfers": """
            CREATE TABLE _transfers_staging (
                from_stop_id TEXT,
                to_stop_id TEXT,
                transfer_type INTEGER,
                min_transfer_time INTEGER,
                PRIMARY KEY (from_stop_id, to_stop_id)
            )""",
        "stop_route_map": """
            CREATE TABLE _stop_route_map_staging (
                stop_id TEXT,
                route_id TEXT,
                direction_id INTEGER,
                PRIMARY KEY (stop_id, route_id, direction_id)
            )""",
        "active_services": """
            CREATE TABLE _active_services_staging (
                service_date INTEGER,
                service_id TEXT,
                PRIMARY KEY (service_date, service_id)
            )""",
        "source_file_versions": """
            CREATE TABLE _source_file_versions_staging (
                file_name TEXT PRIMARY KEY,
                checksum TEXT NOT NULL,
                last_loaded INTEGER NOT NULL,
                layer TEXT NOT NULL
            )""",
        "service_runtime_state": """
            CREATE TABLE _service_runtime_state_staging (
                state_key TEXT PRIMARY KEY,
                feed_valid INTEGER NOT NULL,
                last_successful_sync INTEGER,
                next_refresh_at INTEGER,
                stale_reason TEXT,
                active_services_generated_at INTEGER
            )""",
        "feed_metadata": """
            CREATE TABLE _feed_metadata_staging (
                feed_id TEXT PRIMARY KEY,
                schema_version INTEGER NOT NULL,
                generated_at INTEGER NOT NULL,
                valid_from INTEGER NOT NULL,
                valid_to INTEGER NOT NULL
            )"""
    }

    # Also create the actual final tables (empty) for the swap.
    for tbl, create_sql in tables_sql.items():
        cur.execute(create_sql)
        # Create matching final table name
        final_sql = create_sql.replace('_staging', '')
        cur.execute(final_sql)

    # ------------------------------------------------------------------
    # Parse and load each GTFS file
    # ------------------------------------------------------------------
    with zipfile.ZipFile(gtfs_zip_path, 'r') as zf:
        # --- routes.txt ---
        with zf.open('routes.txt') as f:
            reader = csv.DictReader(io.TextIOWrapper(f, 'utf-8'))
            for row in reader:
                cur.execute(
                    "INSERT INTO _routes_staging VALUES (?,?,?,?)",
                    (
                        row['route_id'].strip(),
                        row['route_short_name'].strip(),
                        row['route_long_name'].strip(),
                        int(row['route_type'].strip())
                    )
                )

        # --- stops.txt ---
        stops = []
        with zf.open('stops.txt') as f:
            reader = csv.DictReader(io.TextIOWrapper(f, 'utf-8'))
            for row in reader:
                stop = {
                    'stop_id': row['stop_id'].strip(),
                    'stop_name': row['stop_name'].strip(),
                    'stop_lat': float(row['stop_lat'].strip()),
                    'stop_lon': float(row['stop_lon'].strip()),
                    'location_type': int(row.get('location_type', '0').strip()),
                    'wheelchair_boarding': int(row.get('wheelchair_boarding', '0').strip())
                }
                stops.append(stop)
                cur.execute(
                    "INSERT INTO _stops_staging VALUES (?,?,?,?,?,?)",
                    (stop['stop_id'], stop['stop_name'], stop['stop_lat'],
                     stop['stop_lon'], stop['location_type'], stop['wheelchair_boarding'])
                )

        # --- shapes.txt → trip_geometry ---
        shapes = {}
        with zf.open('shapes.txt') as f:
            reader = csv.DictReader(io.TextIOWrapper(f, 'utf-8'))
            for row in reader:
                shape_id = row['shape_id'].strip()
                lat = float(row['shape_pt_lat'].strip())
                lon = float(row['shape_pt_lon'].strip())
                seq = int(row['shape_pt_sequence'].strip())
                shapes.setdefault(shape_id, []).append((seq, lat, lon))

        for shape_id, points in shapes.items():
            points.sort(key=lambda x: x[0])
            coords = [(lat, lon) for _, lat, lon in points]
            polyline = encode_polyline(coords)
            cur.execute("INSERT INTO _trip_geometry_staging VALUES (?,?)", (shape_id, polyline))

        # --- calendar.txt ---
        with zf.open('calendar.txt') as f:
            reader = csv.DictReader(io.TextIOWrapper(f, 'utf-8'))
            for row in reader:
                cur.execute(
                    "INSERT INTO _calendar_staging VALUES (?,?,?,?,?,?,?,?,?,?)",
                    (
                        row['service_id'].strip(),
                        int(row['monday'].strip()),
                        int(row['tuesday'].strip()),
                        int(row['wednesday'].strip()),
                        int(row['thursday'].strip()),
                        int(row['friday'].strip()),
                        int(row['saturday'].strip()),
                        int(row['sunday'].strip()),
                        int(row['start_date'].strip()),
                        int(row['end_date'].strip())
                    )
                )

        # --- calendar_dates.txt ---
        with zf.open('calendar_dates.txt') as f:
            reader = csv.DictReader(io.TextIOWrapper(f, 'utf-8'))
            for row in reader:
                cur.execute(
                    "INSERT INTO _calendar_dates_staging VALUES (?,?,?)",
                    (
                        row['service_id'].strip(),
                        int(row['date'].strip()),
                        int(row['exception_type'].strip())
                    )
                )

        # --- trips.txt ---
        trips = []
        with zf.open('trips.txt') as f:
            reader = csv.DictReader(io.TextIOWrapper(f, 'utf-8'))
            for row in reader:
                trip = {
                    'trip_id': row['trip_id'].strip(),
                    'route_id': row['route_id'].strip(),
                    'service_id': row['service_id'].strip(),
                    'direction_id': int(row['direction_id'].strip()),
                    'shape_id': row['shape_id'].strip()
                }
                trips.append(trip)
                cur.execute(
                    "INSERT INTO _trips_staging VALUES (?,?,?,?,?)",
                    (trip['trip_id'], trip['route_id'], trip['service_id'],
                     trip['direction_id'], trip['shape_id'])
                )

        # --- stop_times.txt (streaming interpolation) ---
        print("Processing stop_times.txt with streaming interpolation...")
        with zf.open('stop_times.txt') as f:
            reader = csv.DictReader(io.TextIOWrapper(f, 'utf-8'))
            trip_buffer = []
            current_trip = None
            for row in reader:
                trip_id = row['trip_id'].strip()
                if current_trip is None:
                    current_trip = trip_id
                if trip_id != current_trip:
                    # Flush previous trip after interpolation
                    interpolate_stop_times(trip_buffer)
                    cur.executemany(
                        "INSERT INTO _stop_times_staging VALUES (?,?,?,?,?)",
                        [(r['trip_id'], r['stop_sequence'], r['stop_id'],
                          r['arrival_time_seconds'], r['departure_time_seconds'])
                         for r in trip_buffer]
                    )
                    trip_buffer = []
                    current_trip = trip_id
                # Prepare row
                trip_buffer.append({
                    'trip_id': trip_id,
                    'stop_sequence': int(row['stop_sequence'].strip()),
                    'stop_id': row['stop_id'].strip(),
                    'arrival_time': row['arrival_time'].strip(),
                    'departure_time': row['departure_time'].strip()
                })
            # Last trip
            if trip_buffer:
                interpolate_stop_times(trip_buffer)
                cur.executemany(
                    "INSERT INTO _stop_times_staging VALUES (?,?,?,?,?)",
                    [(r['trip_id'], r['stop_sequence'], r['stop_id'],
                      r['arrival_time_seconds'], r['departure_time_seconds'])
                     for r in trip_buffer]
                )
        print("stop_times loaded.")

    # ------------------------------------------------------------------
    # Generate transfers (static layer, depends on stops)
    # ------------------------------------------------------------------
    generate_transfers(cur, stops)

    # ------------------------------------------------------------------
    # Materialize stop_route_map
    # ------------------------------------------------------------------
    cur.execute("""
        INSERT INTO _stop_route_map_staging
        SELECT DISTINCT st.stop_id, t.route_id, t.direction_id
        FROM _stop_times_staging st
        JOIN _trips_staging t ON st.trip_id = t.trip_id
    """)
    # ------------------------------------------------------------------
    # Materialize active_services (expand calendar + overrides)
    # ------------------------------------------------------------------
    cur.execute("SELECT * FROM _calendar_staging")
    cal = cur.fetchall()
    services = {}  # date -> set(service_ids)
    for (svc_id, mon, tue, wed, thu, fri, sat, sun, start, end) in cal:
        from datetime import timedelta, date
        d = date(start//10000, (start//100)%100, start%100)
        end_d = date(end//10000, (end//100)%100, end%100)
        while d <= end_d:
            weekday = d.weekday()
            active = [mon, tue, wed, thu, fri, sat, sun][weekday]
            date_int = d.year*10000 + d.month*100 + d.day
            if active:
                services.setdefault(date_int, set()).add(svc_id)
            d += timedelta(days=1)
    # Apply calendar_dates overrides
    cur.execute("SELECT service_id, date, exception_type FROM _calendar_dates_staging")
    for svc_id, d, ex_type in cur:
        if ex_type == 1:  # added
            services.setdefault(d, set()).add(svc_id)
        elif ex_type == 2:  # removed
            if d in services:
                services[d].discard(svc_id)

    active_rows = []
    for d, svc_set in services.items():
        for sid in svc_set:
            active_rows.append((d, sid))
    cur.executemany("INSERT INTO _active_services_staging VALUES (?,?)", active_rows)

    # ------------------------------------------------------------------
    # Create indexes on staging tables (after bulk insert)
    # ------------------------------------------------------------------
    index_sqls = [
        "CREATE INDEX idx_routes_short_name ON _routes_staging(route_short_name)",
        "CREATE INDEX idx_trips_route ON _trips_staging(route_id)",
        "CREATE INDEX idx_trips_service ON _trips_staging(service_id, route_id)",
        "CREATE INDEX idx_trips_shape ON _trips_staging(shape_id)",
        "CREATE INDEX idx_st_arrival_backwards ON _stop_times_staging(stop_id, arrival_time_seconds DESC)",
        "CREATE INDEX idx_st_departure ON _stop_times_staging(stop_id, departure_time_seconds)",
        "CREATE INDEX idx_st_trip ON _stop_times_staging(trip_id, stop_sequence)",
        "CREATE INDEX idx_stops_spatial ON _stops_staging(stop_lat, stop_lon)",
        "CREATE INDEX idx_calendar_range ON _calendar_staging(start_date, end_date)",
        "CREATE INDEX idx_transfers_from ON _transfers_staging(from_stop_id, min_transfer_time)",
        "CREATE INDEX idx_srm_directional ON _stop_route_map_staging(stop_id, direction_id, route_id)",
        "CREATE INDEX idx_active_services_date ON _active_services_staging(service_date)"
    ]
    for sql in index_sqls:
        cur.execute(sql)

    # ------------------------------------------------------------------
    # ANALYZE staging tables
    # ------------------------------------------------------------------
    cur.execute("ANALYZE")

    # ------------------------------------------------------------------
    # Atomic swap: drop production, rename staging
    # ------------------------------------------------------------------
    table_names = list(tables_sql.keys())
    conn.commit()                            # ← close any implicit transaction
    cur.execute("BEGIN")
    for tbl in table_names:
        cur.execute(f"DROP TABLE IF EXISTS {tbl}")
        cur.execute(f"ALTER TABLE _{tbl}_staging RENAME TO {tbl}")
    cur.execute("COMMIT")

    # ------------------------------------------------------------------
    # Write feed_metadata (valid_from/to from calendar min/max)
    # ------------------------------------------------------------------
    cur.execute("SELECT MIN(start_date), MAX(end_date) FROM calendar")
    min_d, max_d = cur.fetchone()
    cur.execute(
        "INSERT INTO feed_metadata (feed_id, schema_version, generated_at, valid_from, valid_to) "
        "VALUES (?, ?, ?, ?, ?)",
        ("lynx", 1, UNIX_NOW, min_d, max_d)
    )

    # ------------------------------------------------------------------
    # Write source_file_versions (for future incremental runs)
    # ------------------------------------------------------------------
    for fname in ['routes.txt', 'stops.txt', 'shapes.txt', 'trips.txt',
                  'stop_times.txt', 'calendar.txt', 'calendar_dates.txt']:
        layer = 'static' if fname in ('routes.txt', 'stops.txt', 'shapes.txt') else 'volatile'
        cur.execute(
            "INSERT INTO source_file_versions VALUES (?, ?, ?, ?)",
            (fname, 'hash_not_used_yet', UNIX_NOW, layer)
        )

    # ------------------------------------------------------------------
    # service_runtime_state
    # ------------------------------------------------------------------
    cur.execute(
        "INSERT INTO service_runtime_state VALUES ('primary', 1, ?, ?, NULL, ?)",
        (UNIX_NOW, UNIX_NOW + 7*86400, UNIX_NOW)
    )

    # ------------------------------------------------------------------
    # VACUUM and finalize
    # ------------------------------------------------------------------
    conn.commit()          # <-- close any pending
    conn.execute("VACUUM")
    conn.close()
    print(f"ETL complete. Database saved to {DB_PATH}")

# ----------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------
if __name__ == '__main__':
    if len(sys.argv) != 3:
        print("Usage: gtfs_etl.py <gtfs_zip> <output_db>")
        sys.exit(1)
    run_etl(sys.argv[1], sys.argv[2])
