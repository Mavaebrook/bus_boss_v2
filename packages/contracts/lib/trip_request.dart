import 'package:equatable/equatable.dart';

class TripRequest extends Equatable {
  final double destinationLat;
  final double destinationLon;
  final String? address;
  final DateTime? desiredArrivalTime;
  final String mode;

  const TripRequest({
    required this.destinationLat,
    required this.destinationLon,
    this.address,
    this.desiredArrivalTime,
    this.mode = 'mixed',
  });

  @override
  List<Object?> get props => [destinationLat, destinationLon, address, desiredArrivalTime, mode];
}
