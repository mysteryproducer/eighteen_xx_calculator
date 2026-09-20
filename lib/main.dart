import 'package:flutter/material.dart';

import 'screens/game_selection.dart';
import 'services/session_store.dart';

void main() {
  runApp(MyApp(store: SessionStore()));
}

class MyApp extends StatelessWidget {
  final SessionStore store;

  const MyApp({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '18xx Board Scanner',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: GameSelection(store: store),
    );
  }
}
