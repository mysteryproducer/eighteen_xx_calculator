import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/company.dart';
import '../models/company_rules.dart';
import '../models/end_game.dart';
import '../models/game_session.dart';
import '../models/game_title.dart';
import 'company_assets.dart';

/// [percent] of [company] as certificates: those [held] now where they
/// still add up to it; else the director's -- the biggest held, where it is
/// more than a share and still fits -- and the rest in shares of [stake]%
/// (the company's smallest certificate unless said), what its dividends and
/// worth go by either way.
List<int> certificatesFor(Company company, int percent, List<int> held,
    {int? stake}) {
  if (percent <= 0) return const [];
  if (held.fold(0, (total, p) => total + p) == percent) return held;
  final unit = stake ?? company.shareUnit;
  final director = held.fold(0, math.max);
  final certificates = <int>[
    if (director > unit && percent >= director) director,
  ];
  var left = percent - certificates.fold<int>(0, (total, p) => total + p);
  while (left >= unit) {
    certificates.add(unit);
    left -= unit;
  }
  if (left > 0) certificates.add(left);
  return certificates;
}

/// The usual sizes of a share, in percent, for the user to pick from.
const List<int> _usualStakes = [5, 10, 20, 25, 50, 100];

/// [count] shares as shown: whole, or to a tenth.
String _shares(double count) => count == count.roundToDouble()
    ? '${count.round()}'
    : count.toStringAsFixed(1);

/// The game's players and its market in one table: a column per player --
/// their name, cash and shares -- a row per company with its share value,
/// what a share of it is and how much of it the players hold between them,
/// and at the foot what each player is worth, shares at their share values.
/// For setting a game up, keeping up with it, and its end.
class HoldingsTable extends StatefulWidget {
  final GameTitle title;
  final GameSession session;

  /// Called after every change, to save the session.
  final VoidCallback onChanged;

  /// What each player would be worth after end game ORs, to show under what
  /// they are worth now; null where none are worked out.
  final Map<String, int>? worthAfter;

  const HoldingsTable({
    super.key,
    required this.title,
    required this.session,
    required this.onChanged,
    this.worthAfter,
  });

  @override
  State<HoldingsTable> createState() => _HoldingsTableState();
}

class _HoldingsTableState extends State<HoldingsTable> {
  GameSession get _session => widget.session;

  /// Companies added to the table by hand: a marker on the market that no
  /// one holds shares in, or one hidden under another's in the photo.
  final Set<String> _added = {};

  void _changed(VoidCallback change) {
    setState(change);
    widget.onChanged();
  }

  List<Company> get _companies {
    final ids = {
      for (final h in _session.holdings.values) ...h.keys,
      ..._session.sharePrices.keys,
      ..._added,
    };
    return [
      for (final c in widget.title.companies)
        if (ids.contains(c.id)) c,
    ];
  }

  Future<void> _addPlayer() async {
    final name = await askPlayerName(context, taken: _session.players);
    if (name != null) _changed(() => _session.addPlayer(name));
  }

  Future<void> _player(String player, String choice) async {
    switch (choice) {
      case 'rename':
        final name = await askPlayerName(context,
            initial: player, taken: _session.players);
        if (name != null) _changed(() => _session.renamePlayer(player, name));
      case 'remove':
        final sure = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Remove $player?'),
            content: const Text('Their certificates and cash go too.'),
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
      case 'certificate':
        if (!mounted) return;
        final added = await showDialog<(Company, int)>(
          context: context,
          builder: (context) => CertificateDialog(title: widget.title),
        );
        if (added == null) return;
        final (company, percent) = added;
        _changed(() => _session.setHolding(player, company.id, [
              ...?_session.holdings[player]?[company.id],
              percent,
            ]));
    }
  }

  Future<void> _addCompany() async {
    final shown = {for (final c in _companies) c.id};
    final company = await showDialog<Company>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Add a company'),
        children: [
          for (final c in widget.title.companies)
            if (!shown.contains(c.id))
              SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(c),
                child: CompanyLabel(c),
              ),
        ],
      ),
    );
    if (company != null) setState(() => _added.add(company.id));
  }

  /// Makes a share of [company] [stake]%, each player keeping their shares.
  void _setStake(Company company, int stake) =>
      _changed(() => _session.setShareStake(company, stake));

  /// Asks for a size of share not among the usual ones.
  Future<void> _otherStake(Company company) async {
    final controller =
        TextEditingController(text: '${_session.shareStake(company)}');
    final stake = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          final typed = int.tryParse(controller.text.trim());
          final fine = typed != null && typed > 0 && typed <= 100;
          return AlertDialog(
            title: Text('A share of ${company.label}'),
            content: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(suffixText: '%'),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (fine) Navigator.of(context).pop(typed);
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: fine ? () => Navigator.of(context).pop(typed) : null,
                child: const Text('OK'),
              ),
            ],
          );
        },
      ),
    );
    if (stake != null) _setStake(company, stake);
  }

  /// Where the players hold more shares of [company] than whole ones of
  /// what a share is could make -- more than one share over all of it, to
  /// allow for a slip -- and nothing has said what a share of it is, takes
  /// a share to be smaller: the biggest of the usual sizes they then fit.
  /// What it says about it, if it did.
  String? _guessStake(Company company) {
    if (_session.shareStakes.containsKey(company.id)) return null;
    final stake = _session.shareStake(company);
    final percent = _heldOf(company);
    if (percent <= 100 + stake) return null;
    final count = percent / stake;
    for (final smaller in _usualStakes.reversed) {
      if (smaller < stake && count * smaller <= 100 + smaller) {
        _session.setShareStake(company, smaller);
        return '${_shares(count)} shares of ${company.label} are more than '
            '$stake% each could make: taken as $smaller% each. Change it in '
            'the % each column.';
      }
    }
    return null;
  }

  /// How much of [company] the players hold between them, in percent.
  int _heldOf(Company company) => _session.players
      .fold(0, (total, p) => total + _session.percentHeld(p, company.id));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final players = _session.players;
    final rules = CompanyRules(widget.title);
    final calc = EndGame(widget.title, _session.holdings,
        stakes: _session.shareStakes);
    final worth = {
      for (final p in players)
        p: calc.worth(p,
            cash: _session.cash[p] ?? 0, values: _session.sharePrices),
    };
    final leader = worth.values.fold(0, math.max);
    final after = widget.worthAfter;
    final leaderAfter = after == null ? 0 : after.values.fold(0, math.max);
    TextStyle? lead(bool best) =>
        best ? const TextStyle(fontWeight: FontWeight.bold) : null;
    const blank = DataCell(Text(''));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columnSpacing: 14,
            columns: [
              const DataColumn(label: Text('')),
              const DataColumn(label: Text('Share value'), numeric: true),
              const DataColumn(
                label: Text('% each'),
                tooltip: 'What one share is: the players hold shares',
                numeric: true,
              ),
              for (final p in players)
                DataColumn(
                  numeric: true,
                  label: PopupMenuButton<String>(
                    tooltip: 'Change $p',
                    onSelected: (choice) => _player(p, choice),
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'rename', child: Text('Rename')),
                      PopupMenuItem(
                          value: 'certificate',
                          child: Text('Add a certificate')),
                      PopupMenuItem(value: 'remove', child: Text('Remove')),
                    ],
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(p, style: theme.textTheme.titleSmall),
                        const Icon(Icons.arrow_drop_down, size: 18),
                      ],
                    ),
                  ),
                ),
              const DataColumn(
                label: Text('Total'),
                tooltip: "The players' shares between them, and how much of "
                    'the company they make',
                numeric: true,
              ),
            ],
            rows: [
              DataRow(cells: [
                const DataCell(Text('Cash')),
                blank,
                blank,
                for (final p in players)
                  DataCell(NumberField(
                    key: ValueKey('cash-$p'),
                    value: _session.cash[p],
                    onChanged: (v) => _changed(() =>
                        v == null ? _session.cash.remove(p) : _session.cash[p] = v),
                  )),
                blank,
              ]),
              for (final c in _companies)
                DataRow(cells: [
                  DataCell(CompanyLabel(c)),
                  DataCell(NumberField(
                    key: ValueKey('price-${c.id}'),
                    value: _session.sharePrices[c.id],
                    warning: widget.title.market.isEmpty ||
                            _session.sharePrices[c.id] == null ||
                            widget.title.market
                                    .find(_session.sharePrices[c.id]!) !=
                                null
                        ? null
                        : 'Not on the market',
                    onChanged: (v) => _changed(() => v == null
                        ? _session.sharePrices.remove(c.id)
                        : _session.sharePrices[c.id] = v),
                  )),
                  DataCell(_stake(c)),
                  for (final p in players)
                    DataCell(_holding(rules, p, c)),
                  DataCell(_total(theme, c)),
                ]),
              DataRow(cells: [
                DataCell(Text('Worth', style: theme.textTheme.titleSmall)),
                blank,
                blank,
                for (final p in players)
                  DataCell(Text('${worth[p]}',
                      style: lead(worth[p] == leader && leader > 0))),
                blank,
              ]),
              if (after != null)
                DataRow(cells: [
                  DataCell(Text('After the ORs',
                      style: theme.textTheme.titleSmall)),
                  blank,
                  blank,
                  for (final p in players)
                    DataCell(Text('${after[p] ?? 0}',
                        style: lead(after[p] == leaderAfter && leaderAfter > 0))),
                  blank,
                ]),
            ],
          ),
        ),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: _addPlayer,
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Add player'),
            ),
            TextButton.icon(
              onPressed: _addCompany,
              icon: const Icon(Icons.add),
              label: const Text('Add a company'),
            ),
          ],
        ),
      ],
    );
  }

  /// What a share of [company] is, to pick from the usual sizes or type.
  Widget _stake(Company company) {
    final stake = _session.shareStake(company);
    final sizes = {..._usualStakes, company.shareUnit, stake}.toList()..sort();
    return PopupMenuButton<int>(
      key: ValueKey('stake-${company.id}'),
      tooltip: 'What a share of ${company.label} is',
      initialValue: stake,
      onSelected: (size) =>
          size == 0 ? _otherStake(company) : _setStake(company, size),
      itemBuilder: (context) => [
        for (final size in sizes)
          PopupMenuItem(value: size, child: Text('$size%')),
        const PopupMenuItem(value: 0, child: Text('Other…')),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$stake%'),
          const Icon(Icons.arrow_drop_down, size: 18),
        ],
      ),
    );
  }

  /// How many shares of [company] the players hold between them, and how
  /// much of it that is: to check against the certificates on the table.
  Widget _total(ThemeData theme, Company company) {
    final percent = _heldOf(company);
    if (percent == 0) return const Text('');
    final count = percent / _session.shareStake(company);
    final text = Text(
      '${_shares(count)} ($percent%)',
      key: ValueKey('total-${company.id}'),
      style: percent > 100 ? TextStyle(color: theme.colorScheme.error) : null,
    );
    return percent > 100
        ? Tooltip(message: 'More than all of ${company.label}', child: text)
        : text;
  }

  /// A player's holding of [company], in shares to type over; the
  /// certificates behind it kept where they still add up.
  Widget _holding(CompanyRules rules, String player, Company company) {
    final held = _session.holdings[player]?[company.id] ?? const <int>[];
    final stake = _session.shareStake(company);
    final percent = _session.percentHeld(player, company.id);
    final problems = [
      if (percent % stake != 0)
        '$percent% is not whole shares of $stake%.',
      ...rules.certificateProblems(_session, company, player, held),
    ];
    return NumberField(
      key: ValueKey('held-$player-${company.id}'),
      value: percent == 0 ? null : percent ~/ stake,
      // A player seldom holds more than 60%: a figure no second digit could
      // follow is taken as typed.
      most: math.max(1, 60 ~/ stake),
      warning: problems.isEmpty ? null : problems.join(' '),
      onChanged: (v) {
        String? guessed;
        _changed(() {
          _session.setHolding(player, company.id,
              certificatesFor(company, (v ?? 0) * stake, held, stake: stake));
          guessed = _guessStake(company);
        });
        if (guessed case final said?) {
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(SnackBar(content: Text(said)));
        }
      },
    );
  }
}

/// A whole number to type in, showing [value] -- which may change as other
/// figures are typed -- until the user types over it. Emptied, it gives
/// null. A [warning] marks it, said on a long press of its icon. Where it
/// can be no more than [most], a figure that no further digit could follow
/// is taken as typed and the field let go.
class NumberField extends StatefulWidget {
  final int? value;
  final ValueChanged<int?> onChanged;
  final bool bold;
  final String? suffix;
  final String? warning;
  final int? most;

  const NumberField({
    super.key,
    required this.value,
    required this.onChanged,
    this.bold = false,
    this.suffix,
    this.warning,
    this.most,
  });

  @override
  State<NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<NumberField> {
  late final TextEditingController _text =
      TextEditingController(text: widget.value?.toString() ?? '');
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(NumberField old) {
    super.didUpdateWidget(old);
    final shown = widget.value?.toString() ?? '';
    if (!_focus.hasFocus && _text.text != shown) _text.text = shown;
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _typed(String text) {
    final value = int.tryParse(text.trim());
    widget.onChanged(value);
    final most = widget.most;
    if (most != null && value != null && value * 10 > most) _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final warning = widget.warning;
    final error = Theme.of(context).colorScheme.error;
    // The warning goes in the field's own decoration: the field stays the
    // same widget as it comes and goes, so typing carries on.
    return SizedBox(
      width: warning == null ? 64 : 80,
      child: TextField(
        controller: _text,
        focusNode: _focus,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.end,
        style: TextStyle(
          fontWeight: widget.bold ? FontWeight.bold : null,
          color: warning == null ? null : error,
        ),
        decoration: InputDecoration(
          isDense: true,
          suffixText: widget.suffix,
          suffixIcon: warning == null
              ? null
              : Tooltip(
                  message: warning,
                  child: Icon(Icons.error_outline, size: 16, color: error),
                ),
          suffixIconConstraints:
              const BoxConstraints(minWidth: 18, minHeight: 18),
        ),
        onChanged: _typed,
      ),
    );
  }
}

/// Asks which company's certificate, and of what size.
class CertificateDialog extends StatefulWidget {
  final GameTitle title;

  const CertificateDialog({super.key, required this.title});

  @override
  State<CertificateDialog> createState() => _CertificateDialogState();
}

class _CertificateDialogState extends State<CertificateDialog> {
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
