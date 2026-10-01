import 'package:flutter/material.dart';

import '../models/game_session.dart';
import '../models/game_title.dart';
import '../services/session_store.dart';
import '../services/training_log.dart';
import 'session_board.dart';

/// The saved games for one title.
///
/// A session is what makes close-ups worth taking: the board state lives here
/// between photos, so each operating round only needs a picture of what
/// changed rather than a fresh read of the whole board.
class SessionList extends StatefulWidget {
  final GameTitle title;
  final SessionStore store;

  const SessionList({super.key, required this.title, required this.store});

  @override
  State<SessionList> createState() => _SessionListState();
}

class _SessionListState extends State<SessionList> {
  List<GameSession>? _sessions;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sessions = await widget.store.list(titleId: widget.title.id);
    if (mounted) setState(() => _sessions = sessions);
  }

  Future<void> _open(GameSession session) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SessionBoard(
        title: widget.title,
        session: session,
        store: widget.store,
        trainingLog: TrainingLog(),
      ),
    ));
    await _load();
  }

  Future<void> _newGame() async {
    final result = await showDialog<(String, bool)>(
      context: context,
      builder: (context) => const _NewGameDialog(),
    );
    if (result == null) return;
    final session = GameSession.start(
      title: widget.title,
      name: result.$1,
      startedEmpty: result.$2,
    );
    await widget.store.save(session);
    if (!mounted) return;
    await _open(session);
  }

  Future<void> _delete(GameSession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${session.name}"?'),
        content: const Text('The board state for this game will be lost.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.store.delete(session.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final sessions = _sessions;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title.name)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newGame,
        icon: const Icon(Icons.add),
        label: const Text('New game'),
      ),
      body: sessions == null
          ? const Center(child: CircularProgressIndicator())
          : sessions.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'No games yet. Start one, photograph the board, and the '
                      'app will keep track of it from close-ups after that.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: sessions.length,
                  itemBuilder: (context, index) {
                    final session = sessions[index];
                    final doubtful =
                        session.doubtfulHexes(widget.title.map).length;
                    final tiles =
                        session.hexes.values.where((s) => s.tile != null).length;
                    return ListTile(
                      title: Text(session.name),
                      subtitle: Text(
                        '$tiles ${tiles == 1 ? 'tile' : 'tiles'} laid'
                        '${doubtful == 0 ? '' : ', $doubtful to check'}'
                        ' - ${_when(session.updated)}',
                      ),
                      onTap: () => _open(session),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _delete(session),
                      ),
                    );
                  },
                ),
    );
  }

  static String _when(DateTime time) {
    final ago = DateTime.now().difference(time);
    if (ago.inMinutes < 1) return 'just now';
    if (ago.inHours < 1) return '${ago.inMinutes} min ago';
    if (ago.inDays < 1) return '${ago.inHours} h ago';
    if (ago.inDays < 7) return '${ago.inDays} days ago';
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-'
        '${time.day.toString().padLeft(2, '0')}';
  }
}

class _NewGameDialog extends StatefulWidget {
  const _NewGameDialog();

  @override
  State<_NewGameDialog> createState() => _NewGameDialogState();
}

class _NewGameDialogState extends State<_NewGameDialog> {
  final _name = TextEditingController(text: 'Game');
  bool _startedEmpty = true;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('New game'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 16),
            RadioGroup<bool>(
              groupValue: _startedEmpty,
              onChanged: (v) => setState(() => _startedEmpty = v ?? true),
              child: const Column(
                children: [
                  RadioListTile<bool>(
                    value: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('Starting now'),
                    subtitle: Text('No tiles on the board yet'),
                  ),
                  RadioListTile<bool>(
                    value: false,
                    contentPadding: EdgeInsets.zero,
                    title: Text('Already under way'),
                    subtitle: Text('Tiles are down; read them from a photo'),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
                context, (_name.text.trim().isEmpty ? 'Game' : _name.text.trim(), _startedEmpty)),
            child: const Text('Start'),
          ),
        ],
      );
}
