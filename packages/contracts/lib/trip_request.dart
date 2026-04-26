import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

part 'trip_request.g.dart';

@JsonSerializable()
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

  factory TripRequest.fromJson(Map<String, dynamic> json) => _$TripRequestFromJson(json);
  Map<String, dynamic> toJson() => _$TripRequestToJson(this);
}
