import 'package:riverpod/riverpod.dart';
import 'package:transit_realtime/transit_realtime.dart';

import 'query_engine.dart';

/// Provider that yields the path to the GTFS database file.
/// The actual value must be overridden by the app (in main.dart).
final databasePathProvider = Provider<String>((ref) {
  throw UnimplementedError('Override databasePathProvider with the actual DB path');
});

/// The TransitQueryEngine, built once when the database path is ready.
/// It automatically picks up the real‑time prediction cache if available.
final transitQueryEngineProvider = Provider<TransitQueryEngine>((ref) {
  final dbPath = ref.watch(databasePathProvider);
  final predictionCache = ref.watch(predictionCacheProvider);
  return TransitQueryEngine(
    dbPath: dbPath,
    predictionCache: predictionCache,
  );
});
