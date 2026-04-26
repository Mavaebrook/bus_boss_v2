import 'package:drift/drift.dart';

part 'database.g.dart';  // generated file

// ---------------------------------------------------------------------------
// Drift table definitions – mirror the locked production schema exactly.
// ---------------------------------------------------------------------------

// ── 1. routes ──────────────────────────────────────────────────────────────
@DataClassName('Route')
class Routes extends Table {
  TextColumn get routeId => text().named('route_id')();
  TextColumn get routeShortName => text().named('route_short_name')();
  TextColumn get routeLongName => text().named('route_long_name')();
  IntColumn get routeType => integer().named('route_type')();

  @override
  Set<Column> get primaryKey => {routeId};
}

// ── 2. trips ───────────────────────────────────────────────────────────────
@DataClassName('Trip')
class Trips extends Table {
  TextColumn get tripId => text().named('trip_id')();
  TextColumn get routeId => text().named('route_id')();
  TextColumn get serviceId => text().named('service_id')();
  IntColumn get directionId => integer().named('direction_id')();
  TextColumn get shapeId => text().named('shape_id')();

  @override
  Set<Column> get primaryKey => {tripId};
}

// ── 3. stop_times ──────────────────────────────────────────────────────────
@DataClassName('StopTime')
class StopTimes extends Table {
  TextColumn get tripId => text().named('trip_id')();
  IntColumn get stopSequence => integer().named('stop_sequence')();
  TextColumn get stopId => text().named('stop_id')();
  IntColumn get arrivalTimeSeconds => integer().named('arrival_time_seconds')();
  IntColumn get departureTimeSeconds => integer().named('departure_time_seconds')();

  @override
  Set<Column> get primaryKey => {tripId, stopSequence};
}

// ── 4. stops ───────────────────────────────────────────────────────────────
@DataClassName('Stop')
class Stops extends Table {
  TextColumn get stopId => text().named('stop_id')();
  TextColumn get stopName => text().named('stop_name')();
  RealColumn get stopLat => real().named('stop_lat')();
  RealColumn get stopLon => real().named('stop_lon')();
  IntColumn get locationType => integer().named('location_type')();
  IntColumn get wheelchairBoarding => integer().named('wheelchair_boarding')();

  @override
  Set<Column> get primaryKey => {stopId};
}

// ── 5. trip_geometry ───────────────────────────────────────────────────────
@DataClassName('TripGeometry')
class TripGeometries extends Table {
  TextColumn get shapeId => text().named('shape_id')();
  TextColumn get encodedPolyline => text().named('encoded_polyline')();

  @override
  Set<Column> get primaryKey => {shapeId};
}

// ── 6. calendar ────────────────────────────────────────────────────────────
@DataClassName('Calendar')
class Calendars extends Table {
  TextColumn get serviceId => text().named('service_id')();
  IntColumn get monday => integer().named('monday')();
  IntColumn get tuesday => integer().named('tuesday')();
  IntColumn get wednesday => integer().named('wednesday')();
  IntColumn get thursday => integer().named('thursday')();
  IntColumn get friday => integer().named('friday')();
  IntColumn get saturday => integer().named('saturday')();
  IntColumn get sunday => integer().named('sunday')();
  IntColumn get startDate => integer().named('start_date')();
  IntColumn get endDate => integer().named('end_date')();

  @override
  Set<Column> get primaryKey => {serviceId};
}

// ── 7. calendar_dates ──────────────────────────────────────────────────────
@DataClassName('CalendarDate')
class CalendarDates extends Table {
  TextColumn get serviceId => text().named('service_id')();
  IntColumn get date => integer().named('date')();          // YYYYMMDD
  IntColumn get exceptionType => integer().named('exception_type')();

  @override
  Set<Column> get primaryKey => {serviceId, date};
}

// ── 8. active_services (materialized) ──────────────────────────────────────
@DataClassName('ActiveService')
class ActiveServices extends Table {
  IntColumn get serviceDate => integer().named('service_date')(); // YYYYMMDD
  TextColumn get serviceId => text().named('service_id')();

  @override
  Set<Column> get primaryKey => {serviceDate, serviceId};
}

// ── 9. transfers (generated) ───────────────────────────────────────────────
@DataClassName('Transfer')
class Transfers extends Table {
  TextColumn get fromStopId => text().named('from_stop_id')();
  TextColumn get toStopId => text().named('to_stop_id')();
  IntColumn get transferType => integer().named('transfer_type')();
  IntColumn get minTransferTime => integer().named('min_transfer_time')();

  @override
  Set<Column> get primaryKey => {fromStopId, toStopId};
}

// ── 10. stop_route_map (materialized) ──────────────────────────────────────
@DataClassName('StopRouteMap')
class StopRouteMaps extends Table {
  TextColumn get stopId => text().named('stop_id')();
  TextColumn get routeId => text().named('route_id')();
  IntColumn get directionId => integer().named('direction_id')();

  @override
  Set<Column> get primaryKey => {stopId, routeId, directionId};
}

// ── 11. source_file_versions ───────────────────────────────────────────────
@DataClassName('SourceFileVersion')
class SourceFileVersions extends Table {
  TextColumn get fileName => text().named('file_name')();
  TextColumn get checksum => text().named('checksum')();          // SHA-256
  IntColumn get lastLoaded => integer().named('last_loaded')();   // Unix ts
  TextColumn get layer => text().named('layer')();                // 'static' or 'volatile'

  @override
  Set<Column> get primaryKey => {fileName};
}

// ── 12. service_runtime_state ──────────────────────────────────────────────
@DataClassName('ServiceRuntimeState')
class ServiceRuntimeStates extends Table {
  TextColumn get stateKey => text().named('state_key')();                      // 'primary'
  IntColumn get feedValid => integer().named('feed_valid')();                  // 1|0
  IntColumn get lastSuccessfulSync => integer().named('last_successful_sync').nullable()();
  IntColumn get nextRefreshAt => integer().named('next_refresh_at').nullable()();
  TextColumn get staleReason => text().named('stale_reason').nullable()();
  IntColumn get activeServicesGeneratedAt => integer().named('active_services_generated_at').nullable()();

  @override
  Set<Column> get primaryKey => {stateKey};
}

// ── 13. feed_metadata (single row) ─────────────────────────────────────────
@DataClassName('FeedMetadata')
class FeedMetadatas extends Table {
  TextColumn get feedId => text().named('feed_id')();                         // e.g., 'lynx'
  IntColumn get schemaVersion => integer().named('schema_version')();         // manual increment
  IntColumn get generatedAt => integer().named('generated_at')();             // ETL ts
  IntColumn get validFrom => integer().named('valid_from')();                 // YYYYMMDD
  IntColumn get validTo => integer().named('valid_to')();                     // YYYYMMDD

  @override
  Set<Column> get primaryKey => {feedId};
}
