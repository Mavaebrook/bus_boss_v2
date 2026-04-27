import 'package:riverpod/riverpod.dart';
import 'package:transit_realtime/transit_realtime.dart';
import 'package:contracts/contracts.dart';                     // ← ADD THIS
import 'query_engine.dart';

/// Provider that yields the path to the GTFS database file.
///
/// CRITICAL: This MUST be overridden in the ProviderScope at the root of the app
/// (usually in main.dart) after the local file path is resolved.
final databasePathProvider = Provider<String>((ref) {
  throw UnimplementedError(
    'databasePathProvider was not overridden. '
    'Ensure ProviderScope(overrides: [databasePathProvider.overrideWithValue(path)]) is set in main.dart.'
  );
});

/// The TransitQueryEngine provider.
///
/// This is a [Provider] (not FutureProvider) because the engine's construction
/// is synchronous once the path is known.
final transitQueryEngineProvider = Provider<TransitQueryEngine>((ref) {
  final dbPath = ref.watch(databasePathProvider);
  final predictionCache = ref.watch(predictionCacheProvider);

  final engine = TransitQueryEngine(
    dbPath: dbPath,
    predictionCache: predictionCache,
  );

  ref.onDispose(() {
    // engine.dispose();
  });

  return engine;
});

/// A simple provider for the TripPlan, allowing the UI to reactively
/// request a route. Use a family if you want to pass parameters from the UI.
final tripPlanProvider = FutureProvider.family<TripPlan?, TripPlanRequest>((ref, request) async {
  final engine = ref.watch(transitQueryEngineProvider);

  return engine.getTripPlan(
    request.fromStopId,
    request.toStopId,
    deadline: request.deadline,
    earliestDeparture: request.earliestDeparture,
  );
});

/// Helper class to bundle trip request parameters for the family provider
class TripPlanRequest {
  final String fromStopId;
  final String toStopId;
  final DateTime deadline;
  final DateTime? earliestDeparture;

  TripPlanRequest({
    required this.fromStopId,
    required this.toStopId,
    required this.deadline,
    this.earliestDeparture,
  });
}
