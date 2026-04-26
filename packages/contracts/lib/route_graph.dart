import 'package:equatable/equatable.dart';

class RouteSegment extends Equatable {
  final String fromStopId;
  final String toStopId;
  final int departureSeconds;
  final int arrivalSeconds;
  final String routeId;
  final String tripId;
  final int directionId;
  final String? geometryPolyline;

  const RouteSegment({
    required this.fromStopId,
    required this.toStopId,
    required this.departureSeconds,
    required this.arrivalSeconds,
    required this.routeId,
    required this.tripId,
    required this.directionId,
    this.geometryPolyline,
  });

  @override
  List<Object?> get props => [fromStopId, toStopId, departureSeconds, arrivalSeconds, routeId, tripId, directionId, geometryPolyline];
}
