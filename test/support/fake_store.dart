
import 'package:eighteen_scanner/models/game_session.dart';
import 'package:eighteen_scanner/services/session_store.dart';
import 'package:flutter/foundation.dart';

/// A session store that keeps everything in memory and answers immediately.
///
/// Widget tests run on a fake clock that never drives real file reads, so a
/// screen waiting on the disk would hang. The real store is exercised by its
/// own tests instead.
class FakeSessionStore implements SessionStore {
  final Map<String, GameSession> sessions = {};
  final Map<String, Uint8List> pictures = {};
  final Map<String, BareBoard> bareBoards = {};

  @override
  Future<List<GameSession>> list({String? titleId}) {
    final matching = sessions.values
        .where((s) => titleId == null || s.titleId == titleId)
        .toList()
      ..sort((a, b) => b.updated.compareTo(a.updated));
    return SynchronousFuture(matching);
  }

  @override
  Future<void> save(GameSession session) {
    sessions[session.id] = session;
    return SynchronousFuture(null);
  }

  @override
  Future<void> delete(String id) {
    sessions.remove(id);
    pictures.removeWhere((key, _) => key.startsWith('$id/'));
    return SynchronousFuture(null);
  }

  @override
  Future<void> saveHexPicture(String id, String hexId, Uint8List png) {
    pictures['$id/$hexId'] = png;
    return SynchronousFuture(null);
  }

  @override
  Future<Uint8List?> hexPicture(String id, String hexId) =>
      SynchronousFuture(pictures['$id/$hexId']);

  @override
  Future<BareBoard> bareBoard(String titleId) =>
      SynchronousFuture({...?bareBoards[titleId]});

  @override
  Future<void> saveBareBoard(String titleId, BareBoard board) {
    bareBoards[titleId] = {...board};
    return SynchronousFuture(null);
  }
}
