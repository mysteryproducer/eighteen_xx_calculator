import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/company.dart';
import '../models/company_rules.dart';
import '../models/game_session.dart';
import '../models/game_title.dart';
import '../processing/play_area_reader.dart';
import '../widgets/company_assets.dart';
import '../widgets/holdings_table.dart' show askPlayerName;

/// What the user confirmed a photo of a player's area shows.
class PlayAreaConfirmed {
  /// Each company's trains, and the tokens left on its charter where they
  /// were counted, by company id.
  final Map<String, List<String>> trains;
  final Map<String, int> charterTokens;

  /// Whose certificates they are, and what they are, by company id.
  final String? player;
  final Map<String, List<int>> certificates;

  const PlayAreaConfirmed({
    this.trains = const {},
    this.charterTokens = const {},
    this.player,
    this.certificates = const {},
  });

  /// The companies whose charters were confirmed, in the order shown.
  Iterable<String> get companies => trains.keys;

  /// Records it in [session]: a company's trains and tokens replace what
  /// was noted before, and so do the player's certificates in each company
  /// shown -- which say what a share of it is, where they can't be made of
  /// whole shares as the game had it.
  void applyTo(GameSession session, GameTitle title) {
    trains.forEach((company, list) {
      if (list.isEmpty) {
        session.companyTrains.remove(company);
      } else {
        session.companyTrains[company] = List.of(list);
      }
    });
    session.charterTokens.addAll(charterTokens);
    final whose = player;
    if (whose != null && certificates.isNotEmpty) {
      session.addPlayer(whose);
      certificates.forEach((id, percents) {
        if (title.companyById(id) case final company?) {
          session.stakeFromCertificates(company, percents);
        }
        session.setHolding(whose, id, percents);
      });
    }
  }
}

/// Shows what was read from a photo of a player's area -- charters with
/// their trains and tokens, and certificates -- for the user to put right
/// and confirm, with the rules' objections as they go. Pops a
/// [PlayAreaConfirmed], or null if cancelled.
class PlayAreaReview extends StatefulWidget {
  final GameTitle title;
  final GameSession session;
  final PlayAreaReading reading;

  /// The photo, shown small for reference.
  final Uint8List? preview;

  const PlayAreaReview({
    super.key,
    required this.title,
    required this.session,
    required this.reading,
    this.preview,
  });

  @override
  State<PlayAreaReview> createState() => _PlayAreaReviewState();
}

class _CharterDraft {
  Company company;
  List<String> trains;
  int? tokens;

  _CharterDraft(this.company, this.trains, this.tokens);
}

class _CertificateDraft {
  Company company;
  List<int> percents;

  _CertificateDraft(this.company, this.percents);
}

class _PlayAreaReviewState extends State<PlayAreaReview> {
  late final List<_CharterDraft> _charters = [
    for (final c in widget.reading.charters)
      _CharterDraft(c.company, List.of(c.trains), c.tokens),
  ];
  late final List<_CertificateDraft> _certificates = [
    for (final c in widget.reading.certificates)
      _CertificateDraft(c.company, List.of(c.percents)),
  ];
  String? _player;
  final List<String> _newPlayers = [];

  CompanyRules get _rules => CompanyRules(widget.title);

  List<String> get _players => [...widget.session.players, ..._newPlayers];

  Company get _someCompany => widget.title.companies.first;

  void _apply() {
    Navigator.of(context).pop(PlayAreaConfirmed(
      trains: {for (final c in _charters) c.company.id: c.trains},
      charterTokens: {
        for (final c in _charters)
          if (c.tokens != null) c.company.id: c.tokens!,
      },
      player: _player,
      certificates: {
        for (final c in _certificates) c.company.id: c.percents,
      },
    ));
  }

  Future<void> _choosePlayer(String? choice) async {
    if (choice != _newPlayer) {
      setState(() => _player = choice);
      return;
    }
    final name = await askPlayerName(context, taken: _players);
    if (name == null || !mounted) return;
    setState(() {
      _newPlayers.add(name);
      _player = name;
    });
  }

  static const _newPlayer = '\u0000new';

  Widget _companyPicker(Company value, ValueChanged<Company> onChanged) =>
      DropdownButton<Company>(
        value: value,
        isExpanded: true,
        items: [
          for (final c in widget.title.companies)
            DropdownMenuItem(value: c, child: CompanyLabel(c)),
        ],
        onChanged: (c) {
          if (c != null) onChanged(c);
        },
      );

  Widget _charterCard(_CharterDraft draft) {
    final others = [
      for (final c in _charters)
        if (!identical(c, draft)) ...c.trains,
    ];
    final problems = [
      ..._rules.trainProblems(widget.session, draft.company, draft.trains,
          alsoSeen: others),
      if (draft.tokens != null)
        ..._rules.tokenCountProblems(
            widget.session, draft.company, draft.tokens!),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Charter'),
                const SizedBox(width: 12),
                Expanded(
                  child: _companyPicker(draft.company,
                      (c) => setState(() => draft.company = c)),
                ),
                IconButton(
                  tooltip: 'Not a charter',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _charters.remove(draft)),
                ),
              ],
            ),
            Text('Trains', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            TrainPicker(
              title: widget.title,
              trains: draft.trains,
              onChanged: (t) => setState(() => draft.trains = t),
            ),
            CharterTokens(
              company: draft.company,
              value: draft.tokens,
              onChanged: (n) => setState(() => draft.tokens = n),
            ),
            ProblemList(problems),
          ],
        ),
      ),
    );
  }

  Widget _certificateCard(_CertificateDraft draft) {
    final sizes = {...draft.company.shares}.toList()..sort((a, b) => b - a);
    final total = draft.percents.fold(0, (t, p) => t + p);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Certificates'),
                const SizedBox(width: 12),
                Expanded(
                  child: _companyPicker(draft.company,
                      (c) => setState(() => draft.company = c)),
                ),
                IconButton(
                  tooltip: 'Not certificates',
                  icon: const Icon(Icons.close),
                  onPressed: () =>
                      setState(() => _certificates.remove(draft)),
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (int i = 0; i < draft.percents.length; i++)
                  InputChip(
                    label: Text('${draft.percents[i]}%'),
                    onDeleted: () =>
                        setState(() => draft.percents.removeAt(i)),
                  ),
                Text('= $total%'),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              children: [
                for (final size in sizes)
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 16),
                    label: Text('$size%'),
                    onPressed: () => setState(() => draft.percents.add(size)),
                  ),
              ],
            ),
            ProblemList(_rules.certificateProblems(
                widget.session, draft.company, _player, draft.percents)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final nothing = widget.reading.isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text("A player's area"),
        actions: [
          TextButton(onPressed: _apply, child: const Text('Apply')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(8),
        children: [
          if (widget.preview != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(widget.preview!,
                    height: 180, fit: BoxFit.contain),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              nothing
                  ? "No company's name could be read in the photo. Add what "
                      'it shows by hand, or try again closer, without glare '
                      'on the cards.'
                  : 'Check what was read, put right anything that is wrong, '
                      'and apply it.',
            ),
          ),
          for (final c in _charters) _charterCard(c),
          if (_certificates.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(
                children: [
                  const Text('Whose certificates?'),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButton<String>(
                      value: _player,
                      isExpanded: true,
                      hint: const Text('Choose a player'),
                      items: [
                        for (final p in _players)
                          DropdownMenuItem(value: p, child: Text(p)),
                        const DropdownMenuItem(
                          value: _newPlayer,
                          child: Text('New player...'),
                        ),
                      ],
                      onChanged: _choosePlayer,
                    ),
                  ),
                ],
              ),
            ),
          if (_certificates.isNotEmpty && _player == null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                "Certificates are only recorded once you've said whose they "
                'are.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          for (final c in _certificates) _certificateCard(c),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => setState(() => _charters
                      .add(_CharterDraft(_someCompany, [], null))),
                  icon: const Icon(Icons.add),
                  label: const Text('A charter'),
                ),
                OutlinedButton.icon(
                  onPressed: () => setState(() =>
                      _certificates.add(_CertificateDraft(_someCompany, []))),
                  icon: const Icon(Icons.add),
                  label: const Text('Certificates'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _apply, child: const Text('Apply')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
