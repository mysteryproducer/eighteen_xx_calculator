import 'package:flutter/material.dart';

import '../models/game_session.dart';
import '../models/game_title.dart';
import '../services/photo_pipeline.dart';
import '../widgets/holdings_table.dart';
import 'market_photo.dart';

/// The game's players and its market, at any point in the game: each
/// player's name, cash and certificates, each company's share value -- typed
/// in, or read off a photo of the market -- and what each player is worth.
class PlayersScreen extends StatefulWidget {
  final GameTitle title;
  final GameSession session;
  final PhotoPipeline pipeline;

  /// Called after every change, to save the session.
  final VoidCallback onChanged;

  const PlayersScreen({
    super.key,
    required this.title,
    required this.session,
    this.pipeline = const PhotoPipeline(),
    required this.onChanged,
  });

  @override
  State<PlayersScreen> createState() => _PlayersScreenState();
}

class _PlayersScreenState extends State<PlayersScreen> {
  bool _busy = false;

  Future<void> _photographMarket() async {
    final said = await photographMarket(context,
        title: widget.title,
        session: widget.session,
        pipeline: widget.pipeline,
        onBusy: () => setState(() => _busy = true));
    if (!mounted) return;
    setState(() => _busy = false);
    widget.onChanged();
    if (said != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(said)));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Players and market'),
          actions: [
            IconButton(
              tooltip: 'Photograph the market',
              onPressed: _busy ? null : _photographMarket,
              icon: const Icon(Icons.photo_camera_outlined),
            ),
          ],
        ),
        body: Stack(
          children: [
            ListView(
              padding: const EdgeInsets.all(12),
              children: [
                if (widget.session.players.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      "Add the game's players to keep track of their cash and "
                      'shares, and what each company pays them: a share is '
                      "the % each beside its company -- a director's "
                      "certificate is two. A photo of a player's area can "
                      'fill their certificates in, and one of the market its '
                      'share values.',
                    ),
                  ),
                HoldingsTable(
                  title: widget.title,
                  session: widget.session,
                  onChanged: () {
                    setState(() {});
                    widget.onChanged();
                  },
                ),
              ],
            ),
            if (_busy)
              Container(
                color: Colors.black54,
                alignment: Alignment.center,
                child: const CircularProgressIndicator(),
              ),
          ],
        ),
      );
}
