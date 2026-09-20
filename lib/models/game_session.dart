import 'dart:ui' show Offset;

import 'board.dart';
import 'board_graph.dart';
import 'game_title.dart';
import 'map_layout.dart';
import 'tile_definition.dart';

/// How the app came to believe what is on a hex.
enum HexSource {
  /// Nothing seen yet: printed map at the start of a new game, or unknown.
  assumed,

  /// Read from a photo of the whole board.
  overview,

  /// Read from a close-up.
  closeUp,

  /// Set or confirmed by the user.
  manual,
}

/// What the session believes is on one hex.
class HexState {
  /// The tile on the hex, or null for the printed map alone.
  final PlacedTile? tile;

  /// 0..1: how sure the latest reading was. Manual entries are 1.
  final double confidence;
  final HexSource source;
  final DateTime updated;

  /// The last content the app was sure of. Readings are matched against
  /// this and its legal upgrades, so a doubtful reading never narrows what
  /// the next photo can find.
  final PlacedTile? basis;

  /// Whether [basis] is known at all. False for a game joined part-way that
  /// hasn't had this hex photographed with confidence yet; any tile could be
  /// there.
  final bool basisKnown;

  /// How the hex looked (see `HexPatch`) when it last showed [basis]
  /// confidently, for spotting whether it has changed since.
  final String? reference;
  final Offset? referenceChroma;

  const HexState({
    required this.tile,
    required this.confidence,
    required this.source,
    required this.updated,
    required this.basis,
    this.basisKnown = true,
    this.reference,
    this.referenceChroma,
  });

  /// Confidence below which a hex is flagged for a closer look.
  static const double doubtfulBelow = 0.6;

  bool get isDoubtful => source != HexSource.manual && confidence < doubtfulBelow;

  Map<String, Object?> toJson() => {
        'tile': tile == null ? null : [tile!.tileId, tile!.rotation],
        'confidence': confidence,
        'source': source.name,
        'updated': updated.toIso8601String(),
        'basis': basis == null ? null : [basis!.tileId, basis!.rotation],
        'basisKnown': basisKnown,
        if (reference != null) 'reference': reference,
        if (referenceChroma != null)
          'referenceChroma': [referenceChroma!.dx, referenceChroma!.dy],
      };

  static HexState fromJson(Map<String, Object?> json) {
    PlacedTile? tile(Object? v) => v is List
        ? PlacedTile(v[0] as String, rotation: (v[1] as num).toInt())
        : null;
    final chroma = json['referenceChroma'];
    return HexState(
      tile: tile(json['tile']),
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      source: HexSource.values.asNameMap()[json['source']] ?? HexSource.assumed,
      updated: DateTime.tryParse(json['updated'] as String? ?? '') ?? DateTime(2000),
      basis: tile(json['basis']),
      basisKnown: json['basisKnown'] as bool? ?? true,
      reference: json['reference'] as String?,
      referenceChroma: chroma is List
          ? Offset((chroma[0] as num).toDouble(), (chroma[1] as num).toDouble())
          : null,
    );
  }
}

/// One game in progress: the board as the app last understood it, built up
/// from photos, close-ups and the user's corrections, and saved between
/// sittings so each operating round only needs photos of what changed.
class GameSession {
  final String id;
  final String titleId;
  String name;
  final DateTime created;
  DateTime updated;

  /// The current phase, for off-board and other phase-dependent revenue.
  TileColor phase;

  /// True if the session began with the board as printed (a new game), so
  /// every hex starts known. False for a game joined part-way.
  final bool startedEmpty;

  /// Beliefs about hexes, by printed hex id. Hexes not listed are as printed
  /// (if [startedEmpty]) or unknown.
  final Map<String, HexState> hexes;

  /// Station token owners, by station id (see [StationNode.id]).
  final Map<String, String> tokens;

  /// Revenue the user typed in, by station id.
  final Map<String, int> revenueOverrides;

  GameSession({
    required this.id,
    required this.titleId,
    required this.name,
    required this.created,
    required this.updated,
    this.phase = TileColor.yellow,
    this.startedEmpty = true,
    Map<String, HexState>? hexes,
    Map<String, String>? tokens,
    Map<String, int>? revenueOverrides,
  })  : hexes = hexes ?? {},
        tokens = tokens ?? {},
        revenueOverrides = revenueOverrides ?? {};

  factory GameSession.start({
    required GameTitle title,
    required String name,
    required bool startedEmpty,
    DateTime? now,
  }) {
    final t = now ?? DateTime.now();
    return GameSession(
      id: '${title.id}-${t.microsecondsSinceEpoch}',
      titleId: title.id,
      name: name,
      created: t,
      updated: t,
      startedEmpty: startedEmpty,
    );
  }

  /// What the session believes about [hex], filling in the default for
  /// hexes never touched.
  HexState stateOf(MapHex hex) =>
      hexes[hex.id] ??
      HexState(
        tile: null,
        // Grey and red hexes never change, so they are known either way.
        confidence: startedEmpty || !hex.takesTiles ? 1 : 0,
        source: HexSource.assumed,
        updated: created,
        basis: null,
        basisKnown: startedEmpty || !hex.takesTiles,
      );

  PlacedTile? tileAt(MapHex hex) => stateOf(hex).tile;

  /// Hexes worth a closer look.
  Set<HexCoord> doubtfulHexes(MapLayout map) => {
        for (final hex in map.hexes)
          if (hex.takesTiles && stateOf(hex).isDoubtful) hex.coord,
      };

  /// What is on every hex, turned the right way: the tile if one is laid,
  /// otherwise the printing.
  Map<HexCoord, TileDefinition> content(GameTitle title) {
    final result = <HexCoord, TileDefinition>{};
    for (final hex in title.map.hexes) {
      final tile = tileAt(hex);
      final def = tile == null
          ? hex.printed
          : title.tiles[tile.tileId]?.rotated(tile.rotation) ?? hex.printed;
      result[hex.coord] = def;
    }
    return result;
  }

  /// The route graph for the board as it stands, with token owners filled
  /// in.
  BoardGraph graph(GameTitle title) {
    final graph = BoardGraph.fromContent(content(title), phase: phase);
    for (final station in graph.stations) {
      station.companyId = tokens[station.id];
    }
    return graph;
  }

  /// The user says [hex] holds [tile] (null for nothing laid).
  void setManually(MapHex hex, PlacedTile? tile) {
    final old = stateOf(hex);
    hexes[hex.id] = HexState(
      tile: tile,
      confidence: 1,
      source: HexSource.manual,
      updated: DateTime.now(),
      basis: tile,
      // The last picture showed the old content; keep it only if the user
      // just confirmed that content.
      reference: _same(old.tile, tile) ? old.reference : null,
      referenceChroma: _same(old.tile, tile) ? old.referenceChroma : null,
    );
    updated = DateTime.now();
  }

  /// Records what a photo showed on [hex]: [tile] with [confidence]. A
  /// confident reading becomes the new basis, and [reference] (how the hex
  /// looked) is kept to compare later photos against.
  void recordReading(
    MapHex hex, {
    required PlacedTile? tile,
    required double confidence,
    required HexSource source,
    String? reference,
    Offset? referenceChroma,
  }) {
    final old = stateOf(hex);
    final reliable = confidence >= HexState.doubtfulBelow;
    final now = DateTime.now();
    if (old.source == HexSource.manual && !reliable) {
      // A doubtful reading doesn't override what the user said, but the
      // hex is flagged so someone looks again.
      hexes[hex.id] = HexState(
        tile: old.tile,
        confidence: confidence,
        source: source,
        updated: now,
        basis: old.basis,
        basisKnown: old.basisKnown,
        reference: old.reference,
        referenceChroma: old.referenceChroma,
      );
    } else {
      hexes[hex.id] = HexState(
        tile: tile,
        confidence: confidence,
        source: source,
        updated: now,
        basis: reliable ? tile : old.basis,
        basisKnown: reliable || old.basisKnown,
        reference: reliable ? reference : old.reference,
        referenceChroma: reliable ? referenceChroma : old.referenceChroma,
      );
    }
    updated = now;
  }

  static bool _same(PlacedTile? a, PlacedTile? b) =>
      a?.tileId == b?.tileId && (a == null || a.rotation == b!.rotation);

  /// Bumped when saved state stops meaning what it used to. Version 2 is
  /// where hex sides were renumbered to match tobymao/18xx (see
  /// [HexGeometry]), which changed what a tile's stored rotation means.
  static const int version = 2;

  Map<String, Object?> toJson() => {
        'version': version,
        'id': id,
        'titleId': titleId,
        'name': name,
        'created': created.toIso8601String(),
        'updated': updated.toIso8601String(),
        'phase': phase.name,
        'startedEmpty': startedEmpty,
        'hexes': {for (final e in hexes.entries) e.key: e.value.toJson()},
        'tokens': tokens,
        'revenueOverrides': revenueOverrides,
      };

  static GameSession fromJson(Map<String, Object?> json) {
    final saved = (json['version'] as num?)?.toInt() ?? 1;
    final session = GameSession._fromJson(json);
    if (saved < version) {
      // Tile rotations from before the sides were renumbered would show the
      // tiles turned the wrong way. Keep them on screen as a starting point,
      // but flag every one so it gets checked rather than trusted.
      session.hexes.updateAll((id, state) => HexState(
            tile: state.tile,
            confidence: state.tile == null ? state.confidence : 0,
            source: state.tile == null ? state.source : HexSource.overview,
            updated: state.updated,
            basis: null,
            basisKnown: state.tile == null,
          ));
    }
    return session;
  }

  static GameSession _fromJson(Map<String, Object?> json) => GameSession(
        id: json['id'] as String,
        titleId: json['titleId'] as String,
        name: json['name'] as String? ?? 'Game',
        created: DateTime.parse(json['created'] as String),
        updated: DateTime.parse(json['updated'] as String),
        phase: TileColor.values.asNameMap()[json['phase']] ?? TileColor.yellow,
        startedEmpty: json['startedEmpty'] as bool? ?? true,
        hexes: {
          for (final e in (json['hexes'] as Map? ?? {}).entries)
            e.key as String:
                HexState.fromJson((e.value as Map).cast<String, Object?>()),
        },
        tokens: (json['tokens'] as Map? ?? {}).cast<String, String>(),
        revenueOverrides: {
          for (final e in (json['revenueOverrides'] as Map? ?? {}).entries)
            e.key as String: (e.value as num).toInt(),
        },
      );
}
