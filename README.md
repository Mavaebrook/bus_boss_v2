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

## Future Enhancements

- [ ] **Background GTFS refresh**  
  Use `workmanager` to periodically download and process the GTFS feed, even when the app hasn’t been opened in over a week.
- [ ] **On‑device Dart ETL**  
  Port the Python ETL pipeline to Dart so updates can run completely offline on the phone.
- [ ] **Checksum‑based incremental updates**  
  Only re‑process static files that have changed, using the `source_file_versions` table.
