#!/usr/bin/env bash
set -e

# ───────────────────────────────────────────────────────────
# LYNX Bus Routing App – Repository Scaffold Generator
# Creates the full modular silo architecture inside an
# existing GitHub repository.
# ───────────────────────────────────────────────────────────

PROJECT_NAME="bus_boss_v2"
echo "🚀 Scaffolding $PROJECT_NAME monorepo..."

# 1. Create Flutter project in the current directory (repo root)
flutter create --org com.busboss --platforms android,ios --project-name $PROJECT_NAME .
echo "Flutter project created in $(pwd)"

# Remove default test file (we'll add our own later)
rm -f test/widget_test.dart

# 2. Create top-level directories
mkdir -p packages assets/images assets/gtfs

# 3. Ensure .gitignore is up to date
cat > .gitignore <<'EOF'
# Flutter/Dart
.dart_tool/
.packages
build/
*.iml
*.lock
.vscode/
.idea/

# Database files
*.db
*.sqlite
*.sqlite3

# ETL artifacts
data/

# macOS
.macos/
EOF

# ───────────────────────────────────────────────────────────
# 4. Shared contracts package
# ───────────────────────────────────────────────────────────
echo "📦 Creating contracts package..."
cd packages
dart create -t package contracts
cd contracts
rm -rf test
mkdir -p lib

cat > pubspec.yaml <<'YAML'
name: contracts
description: Shared data models and event definitions for the LYNX Bus Routing system.
version: 1.0.0
publish_to: none

environment:
  sdk: ">=3.0.0 <4.0.0"

dependencies:
  flutter:
    sdk: flutter
  equatable: ^2.0.5
  json_annotation: ^4.8.1

dev_dependencies:
  flutter_lints: ^3.0.0
  build_runner: ^2.4.8
  json_serializable: ^6.7.1
YAML

# Create contract files
cat > lib/contracts.dart <<'DART'
export 'trip_request.dart';
export 'trip_plan.dart';
export 'risk_assessment.dart';
export 'route_graph.dart';
export 'events.dart';
DART

cat > lib/trip_request.dart <<'DART'
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
DART

cat > lib/trip_plan.dart <<'DART'
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
DART

cat > lib/route_graph.dart <<'DART'
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
DART

cat > lib/risk_assessment.dart <<'DART'
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
DART

cat > lib/events.dart <<'DART'
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
DART

cd ../..   # back to repo root

# ───────────────────────────────────────────────────────────
# 5. Create all silo packages
# ───────────────────────────────────────────────────────────
SILOS=(
  "telemetry"
  "motion"
  "presence"
  "transit_etl"
  "transit_query_engine"
  "context_engine"
  "decision_engine"
  "trip_coordinator"
  "intent_sources"
  "user_input"
  "preferences"
  "notification_policy"
  "notification_silo"
  "ui_shell"
  "map_engine"
)

cd packages
for silo in "${SILOS[@]}"; do
  echo "📦 Creating $silo package..."
  dart create -t package "$silo" --force
  cd "$silo"
  rm -rf test

  cat > pubspec.yaml <<YAML
name: $silo
description: $silo silo for the LYNX Bus Routing system.
version: 1.0.0
publish_to: none

environment:
  sdk: ">=3.0.0 <4.0.0"

dependencies:
  flutter:
    sdk: flutter
  contracts:
    path: ../contracts
  riverpod: ^2.5.1
  rxdart: ^0.27.7
  equatable: ^2.0.5

dev_dependencies:
  flutter_lints: ^3.0.0
YAML

  # Add platform-specific deps where appropriate
  case $silo in
    telemetry|motion|presence)
      echo "  geolocator: ^10.1.0" >> pubspec.yaml
      [ "$silo" = "presence" ] && echo "  geofencing: ^0.1.1" >> pubspec.yaml
      ;;
    transit_etl|transit_query_engine)
      echo "  drift: ^2.15.0" >> pubspec.yaml
      echo "  sqlite3: ^2.4.0" >> pubspec.yaml
      echo "  path_provider: ^2.1.0" >> pubspec.yaml
      ;;
    context_engine)
      echo "  dio: ^5.4.0" >> pubspec.yaml
      echo "  cached: ^0.4.0" >> pubspec.yaml
      ;;
    intent_sources)
      echo "  googleapis: ^13.0.0" >> pubspec.yaml
      echo "  google_sign_in: ^6.2.1" >> pubspec.yaml
      echo "  flutter_secure_storage: ^9.0.0" >> pubspec.yaml
      ;;
    user_input)
      echo "  http: ^1.2.1" >> pubspec.yaml
      echo "  geocoding: ^3.0.0" >> pubspec.yaml
      ;;
    preferences)
      echo "  shared_preferences: ^2.2.2" >> pubspec.yaml
      ;;
    notification_silo)
      echo "  flutter_local_notifications: ^17.1.0" >> pubspec.yaml
      echo "  flutter_tts: ^3.6.3" >> pubspec.yaml
      ;;
    ui_shell)
      echo "  flutter_map: ^6.1.0" >> pubspec.yaml
      echo "  flutter_map_tile_caching: ^9.0.0" >> pubspec.yaml
      ;;
    map_engine)
      echo "  flutter_map: ^6.1.0" >> pubspec.yaml
      echo "  flutter_map_tile_caching: ^9.0.0" >> pubspec.yaml
      echo "  vector_map_tiles: ^8.0.0" >> pubspec.yaml
      ;;
  esac

  cat > lib/${silo}.dart <<DART
/// $silo silo – implementation placeholder.
///
/// Exposes its public API via contracts streams / services.
library $silo;

import 'package:contracts/contracts.dart';
import 'package:riverpod/riverpod.dart';
import 'package:rxdart/rxdart.dart';

// TODO: implement $silo logic
DART

  cd ..
done
cd ..   # back to repo root

# ───────────────────────────────────────────────────────────
# 6. Update main app pubspec.yaml
# ───────────────────────────────────────────────────────────
cat > pubspec.yaml <<YAML
name: $PROJECT_NAME
description: "LYNX Bus Routing – modular, offline-first, risk-aware transit app"
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: ">=3.0.0 <4.0.0"

dependencies:
  flutter:
    sdk: flutter
  contracts:
    path: packages/contracts
  telemetry:
    path: packages/telemetry
  motion:
    path: packages/motion
  presence:
    path: packages/presence
  transit_etl:
    path: packages/transit_etl
  transit_query_engine:
    path: packages/transit_query_engine
  context_engine:
    path: packages/context_engine
  decision_engine:
    path: packages/decision_engine
  trip_coordinator:
    path: packages/trip_coordinator
  intent_sources:
    path: packages/intent_sources
  user_input:
    path: packages/user_input
  preferences:
    path: packages/preferences
  notification_policy:
    path: packages/notification_policy
  notification_silo:
    path: packages/notification_silo
  ui_shell:
    path: packages/ui_shell
  map_engine:
    path: packages/map_engine
  flutter_riverpod: ^2.5.1
  rxdart: ^0.27.7

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^3.0.0
  drift_dev: ^2.15.0

flutter:
  uses-material-design: true

  assets:
    - assets/images/
    - assets/gtfs/
YAML

# ───────────────────────────────────────────────────────────
# 7. Prepare main app entry point
# ───────────────────────────────────────────────────────────
cat > lib/main.dart <<'DART'
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_shell/ui_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: LYNXBusApp()));
}

class LYNXBusApp extends StatelessWidget {
  const LYNXBusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LYNX Bus Boss',
      theme: ThemeData.dark().copyWith(
        primaryColor: const Color(0xFF00e5ff),
        scaffoldBackgroundColor: const Color(0xFF0a0c14),
      ),
      home: const UIShell(),
    );
  }
}
DART

# ───────────────────────────────────────────────────────────
# 8. Update README
# ───────────────────────────────────────────────────────────
cat > README.md <<'EOF'
# LYNX Bus Routing App

Modular, offline-first transit app with risk-aware routing and a sarcastic "Bus Boss" coach.

## Project Structure

- `packages/` – domain silos as independent Dart packages
- `packages/contracts` – shared data models and events
- `scripts/gtfs_etl.py` – LYNX GTFS processing pipeline
- `.github/workflows/` – CI/CD workflows

### Getting Started

1. Install Flutter ≥3.16
2. Clone this repo
3. `flutter pub get`
4. Run with `flutter run`

The app requires a pre-built GTFS database (produced by the ETL script) placed in `assets/gtfs/`.
EOF

echo ""
echo "✅ Repository scaffold complete!"
echo "   flutter pub get"
echo "   flutter run"
