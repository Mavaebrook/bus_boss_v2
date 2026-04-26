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
