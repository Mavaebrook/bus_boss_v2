import 'package:equatable/equatable.dart';
import 'package:contracts/route_graph.dart';

class TripPlan extends Equatable {
  final List<RouteSegment> segments;
  final DateTime departureTime;
  final DateTime arrivalTime;
  final double walkDistanceMeters;
  final int transferCount;

  const TripPlan({
    required this.segments,
    required this.departureTime,
    required this.arrivalTime,
    required this.walkDistanceMeters,
    required this.transferCount,
  });

  @override
  List<Object?> get props => [segments, departureTime, arrivalTime, walkDistanceMeters, transferCount];
}
