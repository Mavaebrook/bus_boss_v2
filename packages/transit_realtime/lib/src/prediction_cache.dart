/// In-memory cache of predicted arrival times.
/// Key: stop_id → Map<trip_id, arrival_epoch_seconds>
class PredictionCache {
  final Map<String, Map<String, int>> _cache = {};

  /// Update a trip's predicted arrival at a given stop.
  void updateArrival(String tripId, String stopId, int arrivalEpoch) {
    _cache.putIfAbsent(stopId, () => {});
    _cache[stopId]![tripId] = arrivalEpoch;
  }

  /// Get the predicted arrival for a trip at a stop, or null.
  int? getArrival(String tripId, String stopId) {
    return _cache[stopId]?[tripId];
  }

  /// Remove a trip from the cache (e.g., when service ends).
  void removeTrip(String tripId) {
    for (final stopMap in _cache.values) {
      stopMap.remove(tripId);
    }
  }
}
