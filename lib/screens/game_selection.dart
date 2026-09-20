import 'package:flutter/material.dart';

import '../models/game_title.dart';
import '../services/session_store.dart';
import 'session_list.dart';

/// Pick the 18xx title being played. The title decides which hexes exist,
/// what is printed on them and which tiles are in the box -- all of which
/// recognition leans on heavily.
class GameSelection extends StatelessWidget {
  final SessionStore store;

  const GameSelection({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    final titles = [...GameTitle.all, GameTitle.genericGrid()];
    return Scaffold(
      appBar: AppBar(title: const Text('Select 18xx title')),
      body: ListView.builder(
        itemCount: titles.length,
        itemBuilder: (context, index) {
          final title = titles[index];
          return ListTile(
            title: Text(title.name),
            subtitle: Text(title.id == 'generic'
                ? title.description
                : '${title.description} - ${title.map.hexes.length} hexes, '
                    '${title.tiles.length} tile designs'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => SessionList(title: title, store: store),
            )),
          );
        },
      ),
    );
  }
}
