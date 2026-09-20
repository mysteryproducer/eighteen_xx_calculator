import 'board.dart';
import 'board_graph.dart';
import 'game_title.dart';
import 'map_layout.dart';
import 'tile_definition.dart';

/// One thing that could be on a hex: a tile turned a given way, or (with a
/// null [tileId]) nothing laid over the printed map.
class TileOption {
  final String? tileId;
  final int rotation;

  /// Upgrades between what was known to be there and this option. Zero for
  /// "unchanged".
  final int steps;

  const TileOption(this.tileId, this.rotation, {this.steps = 0});

  static const TileOption printed = TileOption(null, 0);

  bool get isPrinted => tileId == null;

  PlacedTile? get placed =>
      tileId == null ? null : PlacedTile(tileId!, rotation: rotation);

  @override
  bool operator ==(Object other) =>
      other is TileOption && other.tileId == tileId && other.rotation == rotation;

  @override
  int get hashCode => Object.hash(tileId, rotation);

  @override
  String toString() => tileId == null ? 'printed' : '$tileId@$rotation';
}

/// Which tiles could legally be on a hex, given what was there before.
///
/// This is what makes recognition tractable. A photo of one hex, matched
/// against every tile in every rotation, is often ambiguous; matched only
/// against the tiles that the rules allow on top of what was there -- a
/// city tile on a printed city, a green tile that keeps all the yellow
/// tile's track -- it rarely is. The rules here are the common 18xx ones:
///
/// * tiles go on in colour order (yellow, green, brown, grey);
/// * an upgrade keeps every hex side the old tile's track reached;
/// * the number of cities and towns stays the same;
/// * a labelled hex (`OO`, `B`, `Z`...) only takes tiles with its label;
/// * track may not run off the edge of the map or across a printed
///   impassable border.
///
/// Title-specific exceptions aren't modelled; the tile editor still offers
/// every tile for the rare case these rules rule out the real one.
class TileRules {
  final GameTitle title;

  TileRules(this.title);

  /// Everything that could now be on [hex] if [current] was there before
  /// (null meaning nothing had been laid): [TileOption.printed] or current
  /// itself as "unchanged", then upgrades up to [maxSteps] deep.
  List<TileOption> options(MapHex hex, PlacedTile? current, {int maxSteps = 4}) {
    final start = current == null
        ? TileOption.printed
        : TileOption(current.tileId, current.rotation);
    final result = <TileOption>[start];
    if (!hex.takesTiles) return result;

    final seen = <TileOption>{start};
    var frontier = [start];
    for (int step = 1; step <= maxSteps && frontier.isNotEmpty; step++) {
      final next = <TileOption>[];
      for (final from in frontier) {
        for (final option in _upgrades(hex, from)) {
          if (seen.add(option)) {
            final withSteps = TileOption(option.tileId, option.rotation, steps: step);
            result.add(withSteps);
            next.add(withSteps);
          }
        }
      }
      frontier = next;
    }
    return result;
  }

  /// Whether [tile] could be on [hex] at all, starting from the printed map:
  /// the check behind the warning in the tile editor.
  bool fits(MapHex hex, PlacedTile tile) => explain(hex, tile) == null;

  /// Why [tile] doesn't belong on [hex], in a sentence, or null if it does.
  ///
  /// Recognition only ever offers legal tiles, but the editor lets the user
  /// pick any tile, and picking the wrong one (a city where the map prints a
  /// town, say) quietly makes every route through that hex wrong. This says
  /// what is off, so it can be shown rather than discovered later.
  String? explain(MapHex hex, PlacedTile tile) {
    final def = title.tiles[tile.tileId];
    if (def == null) return 'Tile ${tile.tileId} is not in this game.';
    if (!hex.takesTiles) {
      return '${hex.id} is printed on the map; no tile is ever laid here.';
    }
    if (options(hex, null, maxSteps: 4)
        .any((o) => o.tileId == tile.tileId && o.rotation == tile.rotation)) {
      return null;
    }
    final printed = hex.printed;
    String stops(TileDefinition d) {
      final parts = [
        if (d.cityCount > 0) '${d.cityCount} ${d.cityCount == 1 ? 'city' : 'cities'}',
        if (d.townCount > 0) '${d.townCount} ${d.townCount == 1 ? 'town' : 'towns'}',
      ];
      return parts.isEmpty ? 'no stop' : parts.join(' and ');
    }

    if (def.cityCount != printed.cityCount || def.townCount != printed.townCount) {
      return '${hex.id} has ${stops(printed)} printed, but tile '
          '${tile.tileId} has ${stops(def)}.';
    }
    final label = printed.label ?? hex.futureLabel;
    if (def.label != printed.label && def.label != label) {
      return label == null
          ? '${hex.id} takes tiles without a letter, but tile '
              '${tile.tileId} is marked ${def.label}.'
          : '${hex.id} takes $label tiles.';
    }
    final turned = def.rotated(tile.rotation);
    for (final e in turned.edges) {
      if (printed.impassable.contains(e)) {
        return 'Turned this way, tile ${tile.tileId} runs track across the '
            'border printed on ${hex.id}.';
      }
      if (!title.map.contains(Board.neighborOf(hex.coord, e))) {
        return 'Turned this way, tile ${tile.tileId} runs track off the edge '
            'of the map.';
      }
    }
    if (!turned.edges.containsAll(printed.edges)) {
      return 'Turned this way, tile ${tile.tileId} misses the track already '
          'printed on ${hex.id}.';
    }
    // Some other rule: at least say which tiles do fit.
    final fitting = options(hex, null, maxSteps: 4)
        .where((o) => !o.isPrinted)
        .map((o) => o.tileId)
        .toSet();
    return 'The rules don\'t allow tile ${tile.tileId} on ${hex.id}'
        '${fitting.isEmpty ? '' : '; ${fitting.length} other tiles do fit'}.';
  }

  /// The content of [hex] if [option] is on it.
  TileDefinition? contentOf(MapHex hex, TileOption option) => option.isPrinted
      ? hex.printed
      : title.tiles[option.tileId]?.rotated(option.rotation);

  Iterable<TileOption> _upgrades(MapHex hex, TileOption from) sync* {
    final base = contentOf(hex, from);
    if (base == null) return;
    final nextColour = _nextColour(hex, from, base);
    if (nextColour == null) return;
    final requiredLabel = base.label ??
        (nextColour == TileColor.yellow ? null : hex.futureLabel);
    final baseEdges = base.edges;

    for (final tile in title.tiles.values) {
      if (tile.color != nextColour) continue;
      if (tile.label != requiredLabel) continue;
      if (tile.cityCount != base.cityCount || tile.townCount != base.townCount) {
        continue;
      }
      final signatures = <String>{};
      for (int r = 0; r < 6; r++) {
        final turned = tile.rotated(r);
        if (!signatures.add(_signature(turned))) continue; // same as a turn tried
        final edges = turned.edges;
        if (!edges.containsAll(baseEdges)) continue;
        if (!_staysOnMap(hex, edges)) continue;
        if (edges.any(hex.printed.impassable.contains)) continue;
        yield TileOption(tile.id, r);
      }
    }
  }

  TileColor? _nextColour(MapHex hex, TileOption from, TileDefinition base) {
    if (hex.printed.color == TileColor.purple) {
      // Special hexes take their own purple tiles, once.
      return from.isPrinted ? TileColor.purple : null;
    }
    final colour = from.isPrinted && base.color == TileColor.plain
        ? null
        : base.color;
    if (colour == null) return TileColor.yellow;
    final i = tilePhases.indexOf(colour);
    return i < 0 || i + 1 >= tilePhases.length ? null : tilePhases[i + 1];
  }

  bool _staysOnMap(MapHex hex, Set<int> edges) {
    for (final e in edges) {
      if (!title.map.contains(Board.neighborOf(hex.coord, e))) return false;
    }
    return true;
  }

  /// Distinguishes rotations that actually differ: symmetric tiles (a
  /// straight, say) look the same turned three steps.
  static String _signature(TileDefinition def) {
    String end(TileEndpoint e) =>
        e is EdgeEndpoint ? 'e${e.edge}' : 's${(e as StationEndpoint).stationIndex}';
    final parts = [
      for (final seg in def.segments)
        ([end(seg.a), end(seg.b)]..sort()).join('-'),
    ]..sort();
    return parts.join(',');
  }
}
