import 'package:equatable/equatable.dart';

class LocationUpdate extends Equatable {
  final double lat;
  final double lon;
  final double speed;
  final double accuracy;
  final DateTime timestamp;

  const LocationUpdate({
    required this.lat,
    required this.lon,
    required this.speed,
    required this.accuracy,
    required this.timestamp,
  });

  @override
  List<Object?> get props => [lat, lon, speed, accuracy, timestamp];
}

class TripIntent extends Equatable {
  final String source;
  final double destinationLat;
  final double destinationLon;
  final String? address;
  final DateTime deadline;

  const TripIntent({
    required this.source,
    required this.destinationLat,
    required this.destinationLon,
    this.address,
    required this.deadline,
  });

  @override
  List<Object?> get props => [source, destinationLat, destinationLon, address, deadline];
}

class PreferencesUpdated extends Equatable {
  final String key;
  final dynamic value;

  const PreferencesUpdated({required this.key, required this.value});

  @override
  List<Object?> get props => [key, value];
}

class RiskLevelChanged extends Equatable {
  final double newProbability;
  final String action;

  const RiskLevelChanged({required this.newProbability, required this.action});

  @override
  List<Object?> get props => [newProbability, action];
}
