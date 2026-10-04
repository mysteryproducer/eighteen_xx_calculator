import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:path_provider/path_provider.dart';

import '../models/game_session.dart';

/// Saves game sessions on the device, one folder per session:
///
///     sessions/<id>/session.json    the board state
///     sessions/<id>/hexes/<hex>.png the latest photo of each hex
///
/// and with them, how each title's board looks bare, whichever game of it
/// it was photographed empty in:
///
///     sessions/boards/<title>.json
///
/// The per-hex pictures let the tile editor show what the camera saw next to
/// what it was read as.
class SessionStore {
  final Future<Directory> Function() _root;

  SessionStore({Future<Directory> Function()? root})
      : _root = root ?? _defaultRoot;

  static Future<Directory> _defaultRoot() async =>
      Directory('${(await getApplicationDocumentsDirectory()).path}/sessions');

  Future<Directory> _dir(String id) async =>
      Directory('${(await _root()).path}/$id');

  /// Saved sessions, most recently played first; only [titleId]'s if given.
  Future<List<GameSession>> list({String? titleId}) async {
    final root = await _root();
    if (!await root.exists()) return [];
    final sessions = <GameSession>[];
    await for (final entry in root.list()) {
      if (entry is! Directory) continue;
      final file = File('${entry.path}/session.json');
      if (!await file.exists()) continue;
      try {
        final session = GameSession.fromJson(
            (jsonDecode(await file.readAsString()) as Map).cast<String, Object?>());
        if (titleId == null || session.titleId == titleId) sessions.add(session);
      } on FormatException {
        // A half-written or foreign file: skip rather than fail the list.
      }
    }
    sessions.sort((a, b) => b.updated.compareTo(a.updated));
    return sessions;
  }

  Future<void> save(GameSession session) async {
    final dir = await _dir(session.id);
    await dir.create(recursive: true);
    // Write then rename, so a crash mid-save leaves the old file intact.
    final tmp = File('${dir.path}/session.json.tmp');
    await tmp.writeAsString(jsonEncode(session.toJson()));
    await tmp.rename('${dir.path}/session.json');
  }

  Future<void> delete(String id) async {
    final dir = await _dir(id);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<void> saveHexPicture(String id, String hexId, Uint8List png) async {
    final dir = Directory('${(await _dir(id)).path}/hexes');
    await dir.create(recursive: true);
    await File('${dir.path}/$hexId.png').writeAsBytes(png);
  }

  Future<Uint8List?> hexPicture(String id, String hexId) async {
    final file = File('${(await _dir(id)).path}/hexes/$hexId.png');
    return await file.exists() ? file.readAsBytes() : null;
  }

  /// How [titleId]'s board looks bare, as it was last photographed empty in
  /// any game of it; empty if it never has been.
  Future<BareBoard> bareBoard(String titleId) async {
    final file = await _boardFile(titleId);
    if (!await file.exists()) return {};
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return {};
      return {
        for (final MapEntry(:key, :value) in json.entries)
          if (value
              case {
                'darkness': final String darkness,
                'chroma': [final num x, final num y],
              })
            '$key': (darkness, Offset(x.toDouble(), y.toDouble())),
      };
    } on FormatException {
      return {};
    }
  }

  Future<void> saveBareBoard(String titleId, BareBoard board) async {
    final file = await _boardFile(titleId);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      for (final MapEntry(:key, value: (darkness, chroma)) in board.entries)
        key: {
          'darkness': darkness,
          'chroma': [chroma.dx, chroma.dy],
        },
    }));
    await tmp.rename(file.path);
  }

  Future<File> _boardFile(String titleId) async =>
      File('${(await _root()).path}/boards/$titleId.json');
}
