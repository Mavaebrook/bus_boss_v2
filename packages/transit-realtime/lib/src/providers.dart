import 'package:riverpod/riverpod.dart';
import 'prediction_cache.dart';

final predictionCacheProvider = Provider<PredictionCache>((ref) {
  return PredictionCache();
});
