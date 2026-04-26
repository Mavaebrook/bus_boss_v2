import 'package:equatable/equatable.dart';

class RiskAssessment extends Equatable {
  final double probabilityOfFailure;
  final String? recommendedAction;
  final String? explanation;

  const RiskAssessment({
    required this.probabilityOfFailure,
    this.recommendedAction,
    this.explanation,
  });

  @override
  List<Object?> get props => [probabilityOfFailure, recommendedAction, explanation];
}
