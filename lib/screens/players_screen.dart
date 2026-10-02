import 'package:flutter/material.dart';

import '../models/company.dart';
import '../models/company_rules.dart';
import '../models/game_session.dart';
import '../models/game_title.dart';
import '../widgets/company_assets.dart';

/// The game's players, and the share certificates each holds: what their
/// dividends are worked out from.
class PlayersScreen extends StatefulWidget {
  final GameTitle title;
  final GameSession session;

  /// Called after every change, to save the session.
  final VoidCallback onChanged;

  const PlayersScreen({
    super.key,
    required this.title,
    required this.session,
    required this.onChanged,
  });

  @override
  State<PlayersScreen> createState() => _PlayersScreenState();
}

class _PlayersScreenState extends State<PlayersScreen> {
  GameSession get _session => widget.session;

  void _changed(VoidCallback change) {
    setState(change);
    widget.onChanged();
  }

  Future<void> _addPlayer() async {
    final name = await askPlayerName(context, taken: _session.players);
    if (name != null) _changed(() => _session.addPlayer(name));
  }

  Future<void> _rename(String player) async {
    final name =
        await askPlayerName(context, initial: player, taken: _session.players);
    if (name != null) _changed(() => _session.renamePlayer(player, name));
  }

  Future<void> _remove(String player) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove $player?'),
        content: const Text('Their certificates are forgotten too.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (sure == true) _changed(() => _session.removePlayer(player));
  }

  Future<void> _addCertificate(String player) async {
    final added = await showDialog<(Company, int)>(
      context: context,
      builder: (context) => _CertificateDialog(title: widget.title),
    );
    if (added == null) return;
    final (company, percent) = added;
    _changed(() => _session.setHolding(player, company.id, [
          ...?_session.holdings[player]?[company.id],
          percent,
        ]));
  }

  @override
  Widget build(BuildContext context) {
    final rules = CompanyRules(widget.title);
    return Scaffold(
      appBar: AppBar(title: const Text('Players and shares')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addPlayer,
        icon: const Icon(Icons.person_add),
        label: const Text('Add player'),
      ),
      body: _session.players.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  "Add the game's players to keep track of their "
                  'certificates and what each company pays them. A photo '
                  "of a player's area can fill their certificates in.",
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
              children: [
                for (final player in _session.players)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(player,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                              ),
                              PopupMenuButton<String>(
                                tooltip: 'Change $player',
                                onSelected: (choice) => choice == 'rename'
                                    ? _rename(player)
                                    : _remove(player),
                                itemBuilder: (context) => const [
                                  PopupMenuItem(
                                      value: 'rename', child: Text('Rename')),
                                  PopupMenuItem(
                                      value: 'remove', child: Text('Remove')),
                                ],
                              ),
                            ],
                          ),
                          for (final e in (_session.holdings[player] ??
                                  const <String, List<int>>{})
                              .entries)
                            if (widget.title.companyById(e.key)
                                case final company?)
                              _Holding(
                                company: company,
                                percents: e.value,
                                problems: rules.certificateProblems(
                                    _session, company, player, e.value),
                                onChanged: (percents) => _changed(() =>
                                    _session.setHolding(
                                        player, company.id, percents)),
                              ),
                          TextButton.icon(
                            onPressed: () => _addCertificate(player),
                            icon: const Icon(Icons.add),
                            label: const Text('Add a certificate'),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// One company's certificates held by a player, each to take away.
class _Holding extends StatelessWidget {
  final Company company;
  final List<int> percents;
  final List<String> problems;
  final ValueChanged<List<int>> onChanged;

  const _Holding({
    required this.company,
    required this.percents,
    required this.problems,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final total = percents.fold(0, (t, p) => t + p);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              CompanyLabel(company),
              for (int i = 0; i < percents.length; i++)
                InputChip(
                  label: Text('${percents[i]}%'),
                  onDeleted: () => onChanged([...percents]..removeAt(i)),
                ),
              Text('= $total%'),
            ],
          ),
          ProblemList(problems),
        ],
      ),
    );
  }
}

/// Asks which company's certificate, and of what size.
class _CertificateDialog extends StatefulWidget {
  final GameTitle title;

  const _CertificateDialog({required this.title});

  @override
  State<_CertificateDialog> createState() => _CertificateDialogState();
}

class _CertificateDialogState extends State<_CertificateDialog> {
  Company? _company;

  @override
  Widget build(BuildContext context) {
    final company = _company;
    final sizes = company == null
        ? const <int>[]
        : ({...company.shares}.toList()..sort((a, b) => b - a));
    return AlertDialog(
      title: const Text('Add a certificate'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButton<Company>(
            value: company,
            isExpanded: true,
            hint: const Text('Company'),
            items: [
              for (final c in widget.title.companies)
                DropdownMenuItem(value: c, child: CompanyLabel(c)),
            ],
            onChanged: (c) => setState(() => _company = c),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            children: [
              for (final size in sizes)
                ActionChip(
                  label: Text('$size%'),
                  onPressed: () => Navigator.of(context).pop((company!, size)),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// Asks for a player's name, starting from [initial]; null if cancelled.
/// Names already [taken] aren't accepted.
Future<String?> askPlayerName(
  BuildContext context, {
  String initial = '',
  List<String> taken = const [],
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final name = controller.text.trim();
        final clash = name != initial && taken.contains(name);
        void done() {
          if (name.isNotEmpty && !clash) Navigator.of(context).pop(name);
        }

        return AlertDialog(
          title: Text(initial.isEmpty ? 'New player' : 'Rename $initial'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Name',
              errorText: clash ? 'There is a player called that already' : null,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => done(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: name.isEmpty || clash ? null : done,
              child: const Text('OK'),
            ),
          ],
        );
      },
    ),
  );
}
