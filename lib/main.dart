import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:ui_shell/ui_shell.dart';
import 'dart:io';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------------------------------
  // STALE FEED CHECK – run on every cold launch
  // -------------------------------------------------------------------------
  try {
    // Copy the pre‑shipped database from assets to app directory (first run)
    final dbDir = await getApplicationDocumentsDirectory();
    final dbPath = '${dbDir.path}/gtfs.db';
    final dbFile = File(dbPath);
    if (!await dbFile.exists()) {
      final bytes = await rootBundle.load('assets/gtfs/gtfs.db');
      await dbFile.writeAsBytes(bytes.buffer.asUint8List());
    }

    // Open the database and read the latest valid_to date
    final db = sqlite3.sqlite3.open(dbPath);
    final result = db.select('SELECT valid_to FROM feed_metadata LIMIT 1');
    if (result.isNotEmpty) {
      final validTo = result.first['valid_to'] as int;           // YYYYMMDD
      final today = int.parse(
        '${DateTime.now().year}'
        '${DateTime.now().month.toString().padLeft(2, '0')}'
        '${DateTime.now().day.toString().padLeft(2, '0')}',
      );

      if (validTo < today) {
        // Feed is stale – for now log a warning.
        // Later this will trigger a GTFS download + ETL run.
        debugPrint('⚠️ GTFS feed expired (valid_to=$validTo). Update needed.');
      }
    }
    db.dispose();
  } catch (e) {
    debugPrint('Could not check feed freshness: $e');
    // App continues normally even if the check fails
  }
  // -------------------------------------------------------------------------

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
