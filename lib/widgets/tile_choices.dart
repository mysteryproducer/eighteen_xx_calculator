import 'package:flutter/material.dart';

import '../models/map_layout.dart';
import '../models/tile_definition.dart';
import '../models/tile_rules.dart';
import '../processing/tile_renderer.dart';

/// The tiles that could go on a hex, drawn rather than listed.
///
/// A tile's number means nothing at a glance; its shape means everything, and
/// which way round it goes is half the answer. So the first row has each
/// tile once, grouped by colour, drawn the way it fits best; picking one
/// shows a second row of the ways it can be turned, each drawn as it would
/// be laid.
///
/// "Fits best" is how many of its track ends meet track on the hexes around
/// -- what makes a line rather than a stub -- and within each colour the
/// tiles and turns that join up come first. Nothing is left out for not
/// joining up: plenty of legal lays don't.
class TileChoices extends StatelessWidget {
  final MapHex hex;
  final TileRules rules;

  /// Everything on offer: tiles each turned every way allowed, and "nothing
  /// laid".
  final List<TileOption> options;

  final TileOption? selected;
  final ValueChanged<TileOption> onSelected;

  /// Marks the options the rules don't allow, so picking one reads as a
  /// deliberate override.
  final bool Function(TileOption)? isAllowed;

  /// How many of an option's track ends meet track next door.
  final int Function(TileOption)? connections;

  const TileChoices({
    super.key,
    required this.hex,
    required this.rules,
    required this.options,
    required this.onSelected,
    this.selected,
    this.isAllowed,
    this.connections,
  });

  static const double tileSize = 64;

  /// The order colours are shown in: the order tiles are laid in.
  static const List<TileColor> _colourOrder = [
    TileColor.yellow,
    TileColor.green,
    TileColor.brown,
    TileColor.grey,
  ];

  int _links(TileOption o) => connections?.call(o) ?? 0;
  bool _allowed(TileOption o) => isAllowed?.call(o) ?? true;

  /// Best first: joins up most, then allowed, then the lowest turn.
  int _compareTurns(TileOption a, TileOption b) {
    final byLinks = _links(b).compareTo(_links(a));
    if (byLinks != 0) return byLinks;
    if (_allowed(a) != _allowed(b)) return _allowed(a) ? -1 : 1;
    return a.rotation.compareTo(b.rotation);
  }

  @override
  Widget build(BuildContext context) {
    final turns = <String, List<TileOption>>{};
    var offersPrinted = false;
    for (final o in options) {
      if (o.isPrinted) {
        offersPrinted = true;
      } else if (!(turns[o.tileId!]?.contains(o) ?? false)) {
        turns.putIfAbsent(o.tileId!, () => []).add(o);
      }
    }
    for (final list in turns.values) {
      list.sort(_compareTurns);
    }

    // Each colour's tiles, best joined up first.
    TileColor colourOf(String id) => rules.title.tiles[id]?.color ?? TileColor.plain;
    int rank(TileColor c) {
      final i = _colourOrder.indexOf(c);
      return i < 0 ? _colourOrder.length : i;
    }

    final ids = turns.keys.toList()
      ..sort((a, b) {
        final byColour = rank(colourOf(a)).compareTo(rank(colourOf(b)));
        if (byColour != 0) return byColour;
        final byLinks = _links(turns[b]!.first).compareTo(_links(turns[a]!.first));
        if (byLinks != 0) return byLinks;
        return _compareIds(a, b);
      });

    final chosenId = selected?.tileId;
    final items = <Widget>[
      if (offersPrinted)
        _choice(context, TileOption.printed,
            label: 'none', chosen: selected?.isPrinted ?? false),
    ];
    TileColor? group;
    for (final id in ids) {
      final colour = colourOf(id);
      if (items.isNotEmpty && colour != group) items.add(_groupBreak(context));
      group = colour;
      // The chosen tile is shown the way it is turned; the others the way
      // they fit best.
      final shown = id == chosenId && selected != null ? selected! : turns[id]!.first;
      items.add(_choice(context, shown, label: id, chosen: id == chosenId));
    }

    final chosenTurns = chosenId == null ? const <TileOption>[] : turns[chosenId] ?? const [];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row(items),
        if (chosenTurns.length > 1) ...[
          const SizedBox(height: 6),
          Text('Turned:', style: Theme.of(context).textTheme.labelSmall),
          _row([
            for (final o in chosenTurns)
              _choice(context, o,
                  label: _links(o) == 0
                      ? 'turn ${o.rotation}'
                      : 'joins ${_links(o)}',
                  chosen: o == selected,
                  semantics: 'Tile ${o.tileId} turned ${o.rotation}'),
          ]),
        ],
      ],
    );
  }

  Widget _row(List<Widget> children) => SizedBox(
        height: tileSize + 26,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: children.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (_, i) => children[i],
        ),
      );

  Widget _groupBreak(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: VerticalDivider(
          width: 9,
          thickness: 1,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      );

  Widget _choice(
    BuildContext context,
    TileOption option, {
    required String label,
    required bool chosen,
    String? semantics,
  }) {
    final definition = rules.contentOf(hex, option);
    final allowed = _allowed(option);
    return Semantics(
      selected: chosen,
      button: true,
      label: semantics ??
          (option.isPrinted ? 'Nothing laid' : 'Tile ${option.tileId}'),
      child: InkWell(
        onTap: () => onSelected(option),
        borderRadius: BorderRadius.circular(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: tileSize,
              height: tileSize,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  width: chosen ? 3 : 1,
                  color: chosen
                      ? Theme.of(context).colorScheme.primary
                      : allowed
                          ? Colors.black26
                          : Colors.redAccent.withValues(alpha: 0.6),
                ),
              ),
              child: definition == null
                  ? const SizedBox.shrink()
                  : CustomPaint(painter: TilePainter(definition)),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontWeight: chosen ? FontWeight.bold : null,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  static int _compareIds(String a, String b) {
    final na = int.tryParse(a), nb = int.tryParse(b);
    if (na != null && nb != null) return na.compareTo(nb);
    if (na != null) return -1;
    if (nb != null) return 1;
    return a.compareTo(b);
  }
}
