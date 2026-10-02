import 'package:flutter/material.dart';

import '../models/company.dart';
import '../models/company_rules.dart';
import '../models/game_session.dart';
import '../models/game_title.dart';

/// A company's trains as chips to take away, and the title's kinds of
/// train to add.
class TrainPicker extends StatelessWidget {
  final GameTitle title;
  final List<String> trains;
  final ValueChanged<List<String>> onChanged;

  const TrainPicker({
    super.key,
    required this.title,
    required this.trains,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            if (trains.isEmpty) Text('No trains', style: small),
            for (int i = 0; i < trains.length; i++)
              InputChip(
                label: Text(trains[i]),
                onDeleted: () => onChanged([...trains]..removeAt(i)),
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (title.trains.isEmpty)
          SizedBox(
            width: 200,
            child: TextField(
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Add a train (4, 3+, 5E...)',
              ),
              onSubmitted: (name) {
                if (name.trim().isNotEmpty) {
                  onChanged([...trains, name.trim().toUpperCase()]);
                }
              },
            ),
          )
        else
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final t in title.trains)
                ActionChip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: Text(t.name),
                  onPressed: () => onChanged([...trains, t.name]),
                ),
            ],
          ),
      ],
    );
  }
}

/// How many station tokens are left on a company's charter, to step up and
/// down: '?' until counted.
class CharterTokens extends StatelessWidget {
  final Company company;
  final int? value;
  final ValueChanged<int> onChanged;

  const CharterTokens({
    super.key,
    required this.company,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final most = company.tokenCount == 0 ? 9 : company.tokenCount;
    final now = value;
    return Row(
      children: [
        Expanded(
          child: Text(company.tokenCount == 0
              ? 'Tokens left on the charter'
              : 'Tokens left on the charter (of ${company.tokenCount})'),
        ),
        IconButton(
          tooltip: 'One fewer',
          icon: const Icon(Icons.remove),
          onPressed: now == null || now <= 0 ? null : () => onChanged(now - 1),
        ),
        Text(now?.toString() ?? '?'),
        IconButton(
          tooltip: 'One more',
          icon: const Icon(Icons.add),
          onPressed: now != null && now >= most
              ? null
              : () => onChanged(now == null ? 0 : now + 1),
        ),
      ],
    );
  }
}

/// Sentences saying what's wrong, in the colour for errors.
class ProblemList extends StatelessWidget {
  final List<String> problems;

  const ProblemList(this.problems, {super.key});

  @override
  Widget build(BuildContext context) {
    final colour = Theme.of(context).colorScheme.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final p in problems)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber, size: 16, color: colour),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(p,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: colour)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A company's dot and name, for lists.
class CompanyLabel extends StatelessWidget {
  final Company company;

  const CompanyLabel(this.company, {super.key});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(radius: 8, backgroundColor: company.color),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              company.label == company.name
                  ? company.name
                  : '${company.label}  ${company.name}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
}

/// Asks for [company]'s trains and the tokens left on its charter, checked
/// against the title's rules as they're set. Null if cancelled.
Future<({List<String> trains, int? tokens})?> editCompanyAssets(
  BuildContext context, {
  required GameTitle title,
  required GameSession session,
  required Company company,
}) =>
    showModalBottomSheet<({List<String> trains, int? tokens})>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _CompanyAssetsSheet(
        title: title,
        session: session,
        company: company,
      ),
    );

class _CompanyAssetsSheet extends StatefulWidget {
  final GameTitle title;
  final GameSession session;
  final Company company;

  const _CompanyAssetsSheet({
    required this.title,
    required this.session,
    required this.company,
  });

  @override
  State<_CompanyAssetsSheet> createState() => _CompanyAssetsSheetState();
}

class _CompanyAssetsSheetState extends State<_CompanyAssetsSheet> {
  late List<String> _trains =
      List.of(widget.session.companyTrains[widget.company.id] ?? const []);
  late int? _tokens = widget.session.charterTokens[widget.company.id];

  @override
  Widget build(BuildContext context) {
    final rules = CompanyRules(widget.title);
    final problems = [
      ...rules.trainProblems(widget.session, widget.company, _trains),
      if (_tokens != null)
        ...rules.tokenCountProblems(widget.session, widget.company, _tokens!),
    ];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CompanyLabel(widget.company),
              const SizedBox(height: 12),
              Text('Trains', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              TrainPicker(
                title: widget.title,
                trains: _trains,
                onChanged: (t) => setState(() => _trains = t),
              ),
              const SizedBox(height: 8),
              CharterTokens(
                company: widget.company,
                value: _tokens,
                onChanged: (n) => setState(() => _tokens = n),
              ),
              ProblemList(problems),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context)
                        .pop((trains: _trains, tokens: _tokens)),
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
