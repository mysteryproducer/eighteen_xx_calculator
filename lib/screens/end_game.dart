import 'package:flutter/material.dart';

import '../models/company.dart';
import '../models/end_game.dart';
import '../models/game_session.dart';
import '../models/game_title.dart';
import '../processing/train_routes.dart';
import '../services/photo_pipeline.dart';
import '../widgets/company_assets.dart';
import '../widgets/holdings_table.dart';
import 'market_photo.dart';

/// The end of the game: every player's cash, certificates and worth, with
/// the companies' share values typed in or read off a photo of the market --
/// and, if wanted, end game OR sets: the last operating rounds run by
/// themselves on a board that won't change any more.
class EndGameScreen extends StatefulWidget {
  final GameTitle title;
  final GameSession session;
  final PhotoPipeline pipeline;

  /// Called after every change, to save the session.
  final VoidCallback onChanged;

  const EndGameScreen({
    super.key,
    required this.title,
    required this.session,
    this.pipeline = const PhotoPipeline(),
    required this.onChanged,
  });

  @override
  State<EndGameScreen> createState() => _EndGameScreenState();
}

class _EndGameScreenState extends State<EndGameScreen> {
  GameSession get _session => widget.session;

  /// The OR set being worked out, from the game as it stands; none run
  /// until the user asks for some.
  final EndGameSet _draft = EndGameSet(rounds: 1);
  int _rounds = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _draft.revenue.addAll(_routeRevenue());
  }

  void _changed(VoidCallback change) {
    setState(change);
    widget.onChanged();
  }

  /// What each company's trains earn on the board as it stands, where its
  /// trains are noted and it has a token down.
  Map<String, int> _routeRevenue() {
    final graph = _session.graph(widget.title);
    return {
      for (final c in widget.title.companies)
        if (_session.companyTrains[c.id] case final trains?
            when trains.isNotEmpty &&
                graph.stations.any((s) => s.holds(c.id)))
          c.id: TrainRouter(widget.title, graph, c.id).best(trains).revenue,
    };
  }

  EndGame get _calc => EndGame(widget.title, _session.holdings,
      photographedMarket: _session.photographedMarket,
      stakes: _session.shareStakes);

  /// The draft set, starting from the game as it stands.
  EndGameSet get _set {
    _draft
      ..rounds = _rounds.clamp(1, EndGameSet.maxRounds)
      ..cash.clear()
      ..cash.addAll(_session.cash)
      ..prices.clear()
      ..prices.addAll(_session.sharePrices);
    return _draft;
  }

  Future<void> _photographMarket() async {
    final said = await photographMarket(context,
        title: widget.title,
        session: _session,
        pipeline: widget.pipeline,
        onBusy: () => setState(() => _busy = true));
    if (!mounted) return;
    setState(() => _busy = false);
    widget.onChanged();
    if (said != null) _snack(said);
  }

  /// Keeps the OR set worked out, and carries it into the game: each
  /// player paid what it paid them, each share value where it ended -- the
  /// start for a stock round, and the next set.
  void _keep() {
    final set = _set;
    final result = _calc.run(set);
    _changed(() {
      _session.endGameSets.add(EndGameSet(
        cash: Map.of(set.cash),
        prices: Map.of(set.prices),
        holdings: {
          for (final e in _session.holdings.entries)
            e.key: {for (final h in e.value.entries) h.key: List.of(h.value)},
        },
        rounds: set.rounds,
        revenue: Map.of(set.revenue),
        withheld: Set.of(set.withheld),
        corrected: [for (final c in set.corrected) Map.of(c)],
      ));
      for (final p in _session.players) {
        _session.cash[p] = (_session.cash[p] ?? 0) + result.paid(p);
      }
      _session.sharePrices.addAll(result.finalValues);
      _draft.corrected.clear();
      _rounds = 0;
    });
    _snack('OR set kept: cash and share values carried on. Put them right '
        'for any stock round played before the next.');
  }

  void _snack(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final set = _set;
    final result = _rounds == 0 ? null : _calc.run(set);
    final worthAfter = result == null
        ? null
        : {
            for (final p in _session.players)
              p: (_session.cash[p] ?? 0) +
                  result.paid(p) +
                  _calc.sharesWorth(p, result.finalValues),
          };
    return Scaffold(
      appBar: AppBar(
        title: const Text('End of game'),
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
              Text(
                "Each player's cash and shares, and each company's share "
                'value -- typed in, or read off a photo of the market (the '
                'camera above). Worth is cash and shares at their share '
                'values.',
                style: theme.textTheme.bodySmall,
              ),
              HoldingsTable(
                title: widget.title,
                session: _session,
                worthAfter: worthAfter,
                onChanged: () {
                  setState(() {});
                  widget.onChanged();
                },
              ),
              const Divider(),
              Row(
                children: [
                  Expanded(
                    child: Text('End game ORs',
                        style: theme.textTheme.titleMedium),
                  ),
                  SegmentedButton<int>(
                    segments: [
                      for (int n = 0; n <= EndGameSet.maxRounds; n++)
                        ButtonSegment(value: n, label: Text('$n')),
                    ],
                    selected: {_rounds},
                    onSelectionChanged: (picked) =>
                        setState(() => _rounds = picked.single),
                  ),
                ],
              ),
              Text(
                'The last operating rounds run by themselves, if the board '
                'won\'t change: each company pays out what its trains earn '
                'unless it withholds, and its share value moves as the market '
                'says. Type over any share value that came out otherwise; '
                'the rounds after follow from it.',
                style: theme.textTheme.bodySmall,
              ),
              if (result != null) ...[
                _roundsTable(set, result),
                if (result.stuck.isNotEmpty)
                  Text(
                    widget.title.market.isEmpty &&
                            _session.photographedMarket.isEmpty
                        ? "The app doesn't know this game's market: photograph "
                            "it, or type each round's share values."
                        : '${result.stuck.join(', ')}: share value not on the '
                            "market, so it doesn't move.",
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: _keep,
                    icon: const Icon(Icons.check),
                    label: const Text('Keep this OR set'),
                  ),
                ),
              ],
              if (_session.endGameSets.isNotEmpty) ...[
                const Divider(),
                Text('OR sets kept', style: theme.textTheme.titleMedium),
                for (int i = 0; i < _session.endGameSets.length; i++)
                  _keptSet(i),
              ],
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

  /// Each company's takings, whether it pays, and its share value as the
  /// set starts and after each round.
  Widget _roundsTable(EndGameSet set, EndGameResult result) {
    final companies = [
      for (final c in widget.title.companies)
        if (result.values.containsKey(c.id)) c,
    ];
    if (companies.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('Enter the companies\' share values above to run them.'),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 12,
        columns: [
          const DataColumn(label: Text('Company')),
          const DataColumn(label: Text('Takings'), numeric: true),
          const DataColumn(label: Text('Pays')),
          const DataColumn(label: Text('Start'), numeric: true),
          for (int r = 1; r <= set.rounds; r++)
            DataColumn(label: Text('After OR $r'), numeric: true),
        ],
        rows: [
          for (final Company c in companies)
            DataRow(cells: [
              DataCell(CompanyLabel(c)),
              DataCell(NumberField(
                key: ValueKey('takings-${c.id}'),
                value: set.revenue[c.id],
                onChanged: (v) => setState(() => v == null
                    ? set.revenue.remove(c.id)
                    : set.revenue[c.id] = v),
              )),
              DataCell(Checkbox(
                key: ValueKey('pays-${c.id}'),
                value: !set.withheld.contains(c.id),
                onChanged: (pays) => setState(() => pays == true
                    ? set.withheld.remove(c.id)
                    : set.withheld.add(c.id)),
              )),
              DataCell(Text('${result.values[c.id]!.first}')),
              for (int r = 1; r <= set.rounds; r++)
                DataCell(NumberField(
                  key: ValueKey('value-${c.id}-$r'),
                  value: result.values[c.id]![r],
                  bold: result.correctedAt[c.id]?.contains(r) ?? false,
                  onChanged: (v) => setState(() => set.correct(r - 1, c.id, v)),
                )),
            ]),
        ],
      ),
    );
  }

  /// A kept OR set: when, how many rounds, what it paid and where it left
  /// the share values.
  Widget _keptSet(int index) {
    final set = _session.endGameSets[index];
    final result = EndGame(widget.title, set.holdings,
            photographedMarket: _session.photographedMarket)
        .run(set);
    final paid = [
      for (final p in set.holdings.keys)
        if (result.paid(p) > 0) '$p +${result.paid(p)}',
    ];
    final moved = [
      for (final e in result.values.entries)
        '${widget.title.companyById(e.key)?.label ?? e.key} '
            '${e.value.first} → ${e.value.last}',
    ];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('OR set ${index + 1}: ${set.rounds} '
          '${set.rounds == 1 ? 'round' : 'rounds'}'),
      subtitle: Text([
        if (paid.isNotEmpty) 'Paid ${paid.join(', ')}.',
        if (moved.isNotEmpty) '${moved.join(', ')}.',
      ].join(' ')),
      trailing: IconButton(
        tooltip: 'Forget OR set ${index + 1}',
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _changed(() => _session.endGameSets.removeAt(index)),
      ),
    );
  }
}
