import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:transit_etl/transit_etl.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:transit_query_engine/transit_query_engine.dart';
import 'package:ui_shell/ui_shell.dart';
import 'dart:io';

const String gtfsFeedUrl =
    'http://gtfsrt.golynx.com/gtfsrt/google_transit.zip';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  sqlite3.loadSqlite();   // ← CRITICAL: load the native SQLite library before any DB use

  String dbPath;
  try {
    final dbDir = await getApplicationDocumentsDirectory();
    dbPath = '${dbDir.path}/gtfs.db';
    final dbFile = File(dbPath);

    bool needsRefresh = !await dbFile.exists();
    if (!needsRefresh) {
      final db = sqlite3.sqlite3.open(dbPath);
      final result = db.select('SELECT valid_to FROM feed_metadata LIMIT 1');
      if (result.isNotEmpty) {
        final validTo = result.first['valid_to'] as int;
        final today = int.parse(
          '${DateTime.now().year}'
          '${DateTime.now().month.toString().padLeft(2, '0')}'
          '${DateTime.now().day.toString().padLeft(2, '0')}',
        );
        if (validTo < today) {
          needsRefresh = true;
          debugPrint(
              '⚠️ GTFS feed expired (valid_to=$validTo). Downloading new feed…');
        }
      }
      db.dispose();
    }

    if (needsRefresh) {
      debugPrint('📡 Downloading GTFS feed from $gtfsFeedUrl …');
      final response = await http.get(Uri.parse(gtfsFeedUrl));
      if (response.statusCode == 200) {
        final tempZip = '${dbDir.path}/gtfs_update.zip';
        await File(tempZip).writeAsBytes(response.bodyBytes);
        debugPrint('⚙️ Running ETL pipeline…');
        await buildDatabase(tempZip, dbPath);
        debugPrint('✅ Database refreshed successfully.');
        await File(tempZip).delete();
      } else {
        debugPrint('❌ Failed to download feed (HTTP ${response.statusCode}).');
      }
    }
  } catch (e) {
    final dbDir = await getApplicationDocumentsDirectory();
    dbPath = '${dbDir.path}/gtfs.db';
    debugPrint('Feed check/download failed: $e');
  }

  runApp(
    ProviderScope(
      overrides: [
        databasePathProvider.overrideWithValue(dbPath),
      ],
      child: const LYNXBusApp(),
    ),
  );
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
