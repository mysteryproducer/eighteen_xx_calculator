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

/// How the board's colours photograph under the light a game is played in,
/// measured once from a photo (see `BoardReader.calibrate`) and used for
/// every photo after.
///
/// Recognition tells a yellow tile from a green one, or from bare map, by
/// colour as well as shape, and what those colours look like depends on the
/// light: a warm lamp, daylight, a mix. The app's defaults were measured
/// under one warm lamp. A profile replaces them with this game's own.
/// Glare isn't part of it: glare moves with the camera, so each photo is
/// checked for it afresh.
class ColourProfile {
  /// Each colour's chromaticity relative to the bare map around it, as
  /// `ColourModel` uses.
  final Map<TileColor, Offset> colours;
  final DateTime measured;

  const ColourProfile({required this.colours, required this.measured});

  Map<String, Object?> toJson() => {
        'colours': {
          for (final e in colours.entries) e.key.name: [e.value.dx, e.value.dy],
        },
        'measured': measured.toIso8601String(),
      };

  static ColourProfile? fromJson(Object? json) {
    if (json is! Map) return null;
    return ColourProfile(
      colours: {
        for (final e in (json['colours'] as Map? ?? {}).entries)
          if (TileColor.values.asNameMap()[e.key] case final colour?)
            if (e.value case [final num x, final num y])
              colour: Offset(x.toDouble(), y.toDouble()),
      },
      measured: DateTime.tryParse(json['measured'] as String? ?? '') ?? DateTime(2000),
    );
  }
}

/// What a photo showed on a hex the user had set by hand, when it disagreed
/// and wasn't an upgrade: kept for the user to look at, not applied.
class HexSuggestion {
  /// The tile seen, or null for bare map.
  final PlacedTile? tile;
  final double confidence;
  final HexSource source;
  final DateTime when;

  const HexSuggestion({
    required this.tile,
    required this.confidence,
    required this.source,
    required this.when,
  });

  Map<String, Object?> toJson() => {
        'tile': tile == null ? null : [tile!.tileId, tile!.rotation],
        'confidence': confidence,
        'source': source.name,
        'when': when.toIso8601String(),
      };

  static HexSuggestion fromJson(Map<String, Object?> json) {
    final t = json['tile'];
    return HexSuggestion(
      tile: t is List ? PlacedTile(t[0] as String, rotation: (t[1] as num).toInt()) : null,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      source: HexSource.values.asNameMap()[json['source']] ?? HexSource.closeUp,
      when: DateTime.tryParse(json['when'] as String? ?? '') ?? DateTime(2000),
    );
  }
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

  /// On a hex the user set, a photo that disagreed (see [HexSuggestion]).
  final HexSuggestion? suggestion;

  const HexState({
    required this.tile,
    required this.confidence,
    required this.source,
    required this.updated,
    required this.basis,
    this.basisKnown = true,
    this.reference,
    this.referenceChroma,
    this.suggestion,
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
        if (suggestion != null) 'suggestion': suggestion!.toJson(),
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
      suggestion: json['suggestion'] is Map
          ? HexSuggestion.fromJson(
              (json['suggestion'] as Map).cast<String, Object?>())
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

  /// Station tokens: whose token is in each circle of each city, by circle
  /// (see [slotId]). A circle not listed is open.
  final Map<String, String> tokens;

  /// The key the token in circle [slot] of station [stationId] (see
  /// [StationNode.id]) is kept under in [tokens] and [tokenDoubts].
  static String slotId(String stationId, int slot) => '${stationId}_$slot';

  /// The station a key from [slotId] belongs to, and which of its circles.
  static (String, int) circleOf(String slotId) {
    final cut = slotId.lastIndexOf('_');
    return (slotId.substring(0, cut), int.parse(slotId.substring(cut + 1)));
  }

  /// Stations whose token the app placed from a photo without being sure
  /// whose it is. They are shown for the user to check, and a later photo
  /// may change them; setting the token by hand settles it.
  final Set<String> tokenDoubts;

  /// Tunnels driven through a hex (1844), by hex id: the two sides the
  /// tunnel joins. A tunnel adds narrow track to whatever is on the hex.
  final Map<String, (int, int)> tunnels;

  /// Tunnels seen in a photo without much certainty; like [tokenDoubts].
  final Set<String> tunnelDoubts;

  /// Mountain railways (1844), by hex id: the revenue plate on the mountain,
  /// or [unknownPlate] for one seen in a photo that couldn't say which.
  final Map<String, String> mountains;

  /// Mountain railways seen in a photo and not yet confirmed.
  final Set<String> mountainDoubts;

  static const String unknownPlate = '?';

  /// How the board looks under this game's light, if it has been measured.
  ColourProfile? colourProfile;

  /// How washed out by glare each hex was in the latest photo of the whole
  /// board, by hex id. Games are played under the same light, so close-ups
  /// are read knowing where the glare usually falls, as well as what they
  /// show themselves.
  final Map<String, double> glare;

  /// Revenue the user typed in, by station id.
  final Map<String, int> revenueOverrides;

  /// The players, in seating order.
  final List<String> players;

  /// The share certificates each player holds: by player, by company id,
  /// the percentage on each certificate.
  final Map<String, Map<String, List<int>>> holdings;

  /// Each company's trains, by company id: the trains' names.
  final Map<String, List<String>> companyTrains;

  /// Station tokens still on each company's charter, by company id, where
  /// they have been counted.
  final Map<String, int> charterTokens;

  /// The share of [company] that [player] holds, in percent.
  int percentHeld(String player, String company) =>
      (holdings[player]?[company] ?? const <int>[])
          .fold(0, (total, share) => total + share);

  /// Adds a player called [name], unless there is one already.
  void addPlayer(String name) {
    if (name.isNotEmpty && !players.contains(name)) players.add(name);
  }

  /// Renames player [from] to [to], keeping their place and certificates.
  void renamePlayer(String from, String to) {
    final at = players.indexOf(from);
    if (at < 0 || to.isEmpty || from == to || players.contains(to)) return;
    players[at] = to;
    final held = holdings.remove(from);
    if (held != null) holdings[to] = held;
  }

  /// Takes player [name] out of the game, and their certificates with them.
  void removePlayer(String name) {
    players.remove(name);
    holdings.remove(name);
  }

  /// Records that [player] holds [percents] of [company]'s certificates --
  /// all of them, replacing what was noted before.
  void setHolding(String player, String company, List<int> percents) {
    final held = holdings.putIfAbsent(player, () => {});
    if (percents.isEmpty) {
      held.remove(company);
      if (held.isEmpty) holdings.remove(player);
    } else {
      held[company] = List.of(percents);
    }
  }

  /// Which way the board faced in the latest photo of all of it, in radians
  /// clockwise from the photo's x axis to the map's rows running east: zero
  /// when photographed from the map's south edge. Players photograph from
  /// where they sit, so close-ups are framed, and the next photo of the
  /// board looked for, the same way round.
  double? facing;

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
    Set<String>? tokenDoubts,
    Map<String, (int, int)>? tunnels,
    Set<String>? tunnelDoubts,
    Map<String, String>? mountains,
    Set<String>? mountainDoubts,
    Map<String, int>? revenueOverrides,
    this.colourProfile,
    Map<String, double>? glare,
    this.facing,
    List<String>? players,
    Map<String, Map<String, List<int>>>? holdings,
    Map<String, List<String>>? companyTrains,
    Map<String, int>? charterTokens,
  })  : players = players ?? [],
        holdings = holdings ?? {},
        companyTrains = companyTrains ?? {},
        charterTokens = charterTokens ?? {},
        glare = glare ?? {},
        hexes = hexes ?? {},
        tokens = tokens ?? {},
        tokenDoubts = tokenDoubts ?? {},
        tunnels = tunnels ?? {},
        tunnelDoubts = tunnelDoubts ?? {},
        mountains = mountains ?? {},
        mountainDoubts = mountainDoubts ?? {},
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

  /// Hexes the user set where a later photo showed something else.
  Set<HexCoord> suggestedHexes(MapLayout map) => {
        for (final hex in map.hexes)
          if (stateOf(hex).suggestion != null) hex.coord,
      };

  /// What is on every hex, turned the right way: the tile if one is laid,
  /// otherwise the printing.
  Map<HexCoord, TileDefinition> content(GameTitle title) {
    final result = <HexCoord, TileDefinition>{};
    for (final hex in title.map.hexes) {
      final tile = tileAt(hex);
      var def = tile == null
          ? hex.printed
          : title.tiles[tile.tileId]?.rotated(tile.rotation) ?? hex.printed;
      final plate = title.tiles[mountains[hex.id]];
      if (plate != null) def = def.withRevenueFrom(plate);
      final tunnel = tunnels[hex.id];
      if (tunnel != null) {
        def = def.withSegments([
          TileSegment(EdgeEndpoint(tunnel.$1), EdgeEndpoint(tunnel.$2),
              narrow: true),
        ]);
      }
      result[hex.coord] = def;
    }
    return result;
  }

  /// The route graph for the board as it stands, with token owners filled
  /// in.
  BoardGraph graph(GameTitle title) {
    final graph = BoardGraph.fromContent(content(title), phase: phase);
    for (final station in graph.stations) {
      station.tokens = [
        for (int slot = 0; slot < station.tokens.length; slot++)
          tokens[slotId(station.id, slot)],
      ];
    }
    return graph;
  }

  /// Tokens that can't legally be where they are, by circle (see [slotId]),
  /// with why. A company keeps a circle free in its home city until its
  /// home token is down there: no company's starting token can be blocked,
  /// so a token that fills the last free circle of someone else's home is
  /// out of place.
  Map<String, String> tokenProblems(GameTitle title) {
    final problems = <String, String>{};
    for (final station in graph(title).stations) {
      if (station.kind != StationKind.city) continue;
      final hex = title.map.at(station.hex);
      if (hex == null) continue;
      final homes = [
        for (final c in title.companies)
          if (c.isHomeOf(hex.id, station.stationIndex)) c,
      ];
      final waiting = [
        for (final c in homes)
          if (!station.holds(c.id)) c,
      ];
      if (waiting.isEmpty) continue;
      final others = [
        for (int slot = 0; slot < station.tokens.length; slot++)
          if (station.tokens[slot] case final t?
              when !homes.any((c) => c.id == t))
            slot,
      ];
      if (others.length <= station.tokens.length - waiting.length) continue;
      final names = waiting.map((c) => c.label).join(' and ');
      final circles = station.tokens.length == 1
          ? 'its only circle'
          : 'a circle';
      for (final slot in others) {
        problems[slotId(station.id, slot)] =
            '${hex.displayName} is $names\'s home, and $circles has to stay '
            'free until ${waiting.length == 1 ? 'its' : 'their'} home token '
            '${waiting.length == 1 ? 'is' : 'are'} placed.';
      }
    }
    return problems;
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
  ///
  /// What the user set by hand stands. A photo replaces it only with an
  /// [upgrade] of it -- a green tile where they set the yellow one, say,
  /// which is play moving on. A confident photo that shows anything else is
  /// kept as a [HexSuggestion] for them to look at; one that agrees with
  /// them just refreshes how the hex looks; a doubtful one changes nothing.
  void recordReading(
    MapHex hex, {
    required PlacedTile? tile,
    required double confidence,
    required HexSource source,
    String? reference,
    Offset? referenceChroma,
    bool upgrade = false,
  }) {
    final old = stateOf(hex);
    final reliable = confidence >= HexState.doubtfulBelow;
    final now = DateTime.now();
    if (old.source == HexSource.manual && !(reliable && upgrade)) {
      final agrees = _same(old.tile, tile);
      hexes[hex.id] = HexState(
        tile: old.tile,
        confidence: 1,
        source: HexSource.manual,
        updated: old.updated,
        basis: old.basis,
        basisKnown: old.basisKnown,
        reference: agrees && reliable ? reference : old.reference,
        referenceChroma:
            agrees && reliable ? referenceChroma : old.referenceChroma,
        suggestion: agrees
            ? null
            : reliable
                ? HexSuggestion(
                    tile: tile, confidence: confidence, source: source, when: now)
                : old.suggestion,
      );
      if (agrees || reliable) updated = now;
      return;
    }
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
    updated = now;
  }

  static bool _same(PlacedTile? a, PlacedTile? b) =>
      a?.tileId == b?.tileId && (a == null || a.rotation == b!.rotation);

  /// Bumped when saved state stops meaning what it used to. Version 2 is
  /// where hex sides were renumbered to match tobymao/18xx (see
  /// [HexGeometry]), which changed what a tile's stored rotation means.
  /// Version 3 keeps a token per circle of a city rather than one per city.
  static const int version = 3;

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
        'tokenDoubts': tokenDoubts.toList()..sort(),
        'tunnels': {
          for (final e in tunnels.entries) e.key: [e.value.$1, e.value.$2],
        },
        'tunnelDoubts': tunnelDoubts.toList()..sort(),
        if (mountains.isNotEmpty) 'mountains': mountains,
        if (mountainDoubts.isNotEmpty)
          'mountainDoubts': mountainDoubts.toList()..sort(),
        if (colourProfile != null) 'colourProfile': colourProfile!.toJson(),
        if (glare.isNotEmpty)
          'glare': {
            for (final e in glare.entries)
              if (e.value > 0) e.key: double.parse(e.value.toStringAsFixed(2)),
          },
        if (facing != null) 'facing': double.parse(facing!.toStringAsFixed(4)),
        'revenueOverrides': revenueOverrides,
        if (players.isNotEmpty) 'players': players,
        if (holdings.isNotEmpty) 'holdings': holdings,
        if (companyTrains.isNotEmpty) 'companyTrains': companyTrains,
        if (charterTokens.isNotEmpty) 'charterTokens': charterTokens,
      };

  static GameSession fromJson(Map<String, Object?> json) {
    final saved = (json['version'] as num?)?.toInt() ?? 1;
    final session = GameSession._fromJson(json);
    if (saved < 3) {
      // Tokens were kept one per city before each circle had its own: each
      // goes in its city's first circle.
      final old = Map.of(session.tokens);
      session.tokens
        ..clear()
        ..addAll({for (final e in old.entries) slotId(e.key, 0): e.value});
      final doubts = Set.of(session.tokenDoubts);
      session.tokenDoubts
        ..clear()
        ..addAll({for (final id in doubts) slotId(id, 0)});
    }
    if (saved < 2) {
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
        tokenDoubts: {
          for (final id in json['tokenDoubts'] as List? ?? const []) id as String,
        },
        tunnels: {
          for (final e in (json['tunnels'] as Map? ?? {}).entries)
            if (e.value case [final num a, final num b])
              e.key as String: (a.toInt(), b.toInt()),
        },
        tunnelDoubts: {
          for (final id in json['tunnelDoubts'] as List? ?? const []) id as String,
        },
        mountains: (json['mountains'] as Map? ?? {}).cast<String, String>(),
        mountainDoubts: {
          for (final id in json['mountainDoubts'] as List? ?? const []) id as String,
        },
        colourProfile: ColourProfile.fromJson(json['colourProfile']),
        glare: {
          for (final e in (json['glare'] as Map? ?? {}).entries)
            e.key as String: (e.value as num).toDouble(),
        },
        facing: (json['facing'] as num?)?.toDouble(),
        players: [for (final p in json['players'] as List? ?? const []) p as String],
        holdings: {
          for (final e in (json['holdings'] as Map? ?? {}).entries)
            e.key as String: {
              for (final c in (e.value as Map).entries)
                c.key as String: [
                  for (final share in c.value as List) (share as num).toInt(),
                ],
            },
        },
        companyTrains: {
          for (final e in (json['companyTrains'] as Map? ?? {}).entries)
            e.key as String: [for (final t in e.value as List) t as String],
        },
        charterTokens: {
          for (final e in (json['charterTokens'] as Map? ?? {}).entries)
            e.key as String: (e.value as num).toInt(),
        },
        revenueOverrides: {
          for (final e in (json['revenueOverrides'] as Map? ?? {}).entries)
            e.key as String: (e.value as num).toInt(),
        },
      );
}
