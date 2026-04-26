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
