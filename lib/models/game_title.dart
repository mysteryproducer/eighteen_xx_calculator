import 'dart:math' as math;

import '../titles/title_1807.dart';
import '../titles/title_1844.dart';
import '../titles/title_1854.dart';
import '../titles/title_1880.dart';
import '../titles/title_1889.dart';
import '../titles/title_data.dart';
import 'board.dart';
import 'company.dart';
import 'map_layout.dart';
import 'stock_market.dart';
import 'tile_definition.dart';
import 'tile_seed_data.dart';

/// An 18xx title the app knows: its printed map and the tiles in the box.
class GameTitle {
  final String id;
  final String name;
  final String description;
  final MapLayout map;

  /// Tiles players can lay, by id.
  final Map<String, TileDefinition> tiles;

  /// How many of each tile come in the box; one there are as many of as
  /// are wanted (1807's plain track) isn't listed.
  final Map<String, int> tileCounts;

  /// Tiles the game lays by itself rather than a player choosing them: the
  /// ones that appear when 1844's Gotthard tunnel opens.
  final Set<String> laidByGame;

  /// The companies whose tokens go on the board.
  final List<Company> companies;

  /// Hexes a tunnel can be driven through (1844's mountains), and the tiles
  /// whose narrow track gives the ways a tunnel can run.
  final Set<String> tunnelHexes;
  final List<String> tunnelTiles;

  /// Mountains a mountain railway's revenue plate can go on, and the plates
  /// (1844's).
  final Set<String> mountainHexes;
  final List<String> mountainPlates;

  const GameTitle({
    required this.id,
    required this.name,
    required this.description,
    required this.map,
    required this.tiles,
    this.tileCounts = const {},
    this.laidByGame = const {},
    this.companies = Company.defaults,
    this.tunnelHexes = const {},
    this.tunnelTiles = const [],
    this.mountainHexes = const {},
    this.mountainPlates = const [],
    this.flat = false,
    this.specialUpgrades = const {},
    this.tilesOnlyOn = const {},
    this.tileStyle = TileStyle.plain,
    this.doubleSidedTiles = false,
    this.trains = const [],
    this.phases = const [],
    this.halfPay = false,
    this.routeRules = RouteRules.none,
    this.stopGroups = const {},
    this.groupBonus = const {},
    this.market = const StockMarket([]),
    this.marketRules = const MarketRules(),
  });

  /// The stock market, and how a payout moves a price on it (see
  /// [_marketRules]): what the end of the game is worked out on.
  final StockMarket market;
  final MarketRules marketRules;

  /// What a route pays beyond its stops, and where it may not go: rules in
  /// tobymao's game code, kept here by hand (see [_routeRules]).
  final RouteRules routeRules;

  /// The groups each off-board area belongs to (1844's `E`, `W`, `N`, `S`),
  /// by hex id, and what each pays towards a bonus for joining two groups
  /// (see [RouteRules.bonusPairs]).
  final Map<String, Set<String>> stopGroups;
  final Map<String, int> groupBonus;

  /// The kinds of train, and the phases of the game they bring.
  final List<TrainType> trains;
  final List<GamePhase> phases;

  /// The colours of tile the game's phases bring in, in order: the phases
  /// a session can be in. All of them for a title without phases; 1889's
  /// stop at brown, its diesels paying more by train, not by phase.
  List<TileColor> get phaseColours => phases.isEmpty
      ? tilePhases
      : [
          for (final c in tilePhases)
            if (phases.any((p) => p.tiles.contains(c))) c,
        ];

  /// Whether a company may pay out half its revenue and keep half. None of
  /// the titles imported so far lets a player choose to.
  final bool halfPay;

  /// The train called [name], if the title has one.
  TrainType? trainNamed(String name) {
    for (final t in trains) {
      if (t.name == name) return t;
    }
    return null;
  }

  /// Which of a title's trains are measured in hexes rather than stops, by
  /// name: game code in tobymao, kept here by hand. 1844's H trains.
  static final Map<String, bool Function(String)> _hexTrains = {
    '1844': (name) => name.endsWith('H'),
  };

  /// [routeRules] for the titles that have them.
  static const Map<String, RouteRules> _routeRules = {
    '1844': RouteRules(
      noEmptyStops: true,
      narrowBonus: 10,
      bonusPairs: [('E', 'W'), ('N', 'S')],
    ),
  };

  /// [specialUpgrades] for the titles that have them. These are rules in
  /// tobymao/18xx's game code (`upgrades_to?`), not its data, so they are
  /// kept here by hand.
  static const Map<String, Map<String, Set<String>>> _specialUpgrades = {
    '1844': {
      'D15': {'14', '15', '619'},
    },
  };

  /// Hexes whose printing is replaced by a rule of the title's own rather
  /// than the usual one (same number of cities and towns), by hex id: the
  /// tiles that can go on the printing. 1844's Aarau (D15) is printed with
  /// two small cities, which its first tile joins into one of two circles.
  final Map<String, Set<String>> specialUpgrades;

  /// [tilesOnlyOn] for the titles that have them: tiles only a private
  /// company's power lays, in tobymao's company data rather than the tile's.
  static const Map<String, Map<String, Set<String>>> _tilesOnlyOn = {
    '1889': {
      // The port, which the Mitsubishi Ferry lays on a coastal town.
      '437': {'B11', 'G10', 'I12', 'J9'},
    },
  };

  /// Tiles that may go only on certain hexes, by tile id: the hexes.
  final Map<String, Set<String>> tilesOnlyOn;

  /// How the physical tiles print their stops (see [TileStyle]), and
  /// whether they are double-sided -- the other side printing its circles
  /// in a shade of the tile ([TileStyle.shaded]) -- for the edition the
  /// user plays: the tiles of the 1889 the app was tried on.
  final TileStyle tileStyle;
  final bool doubleSidedTiles;
  static const Map<String, TileStyle> _tileStyles = {
    // The circles of 1889's two- and three-city tiles: white discs about a
    // quarter of the hex across, touching (448, 465, 15 photographed).
    '1889': TileStyle(townDots: true, multiSlotRadius: 0.27),
  };
  static const Set<String> _doubleSided = {'1889'};

  /// How each title's share prices move when a company pays out, where it
  /// isn't tobymao's default of a space right for anything paid, and what its
  /// minors pay their owners (from each game's code: `step/dividend.rb`).
  static const Map<String, MarketRules> _marketRules = {
    // 1867's rules: a payout of at least the share price moves it a space
    // right, a smaller one not at all; a minor pays its owner half.
    '1807': MarketRules(payoutMoves: [(1.0, 1)], minorPayout: 0.5),
    // A regional company stops short of the cells marked `t`, going up.
    '1844': MarketRules(barred: {
      't': {'regional'},
    }),
    // A minor pays its owner half.
    '1854': MarketRules(minorPayout: 0.5),
    // The foreign investors keep what they earn.
    '1880': MarketRules(minorPayout: 0),
  };

  /// Whether the board is printed with flat-topped hexes. The app keeps
  /// every map pointy-topped (see [MapLayout.coordFromFlatId]); drawing
  /// turns a flat one back by [displayTurn].
  final bool flat;

  /// How far the app's map is turned, in radians clockwise, to look as the
  /// board is printed: a twelfth of a turn back for a flat-topped board.
  double get displayTurn => flat ? -math.pi / 6 : 0;

  /// The company with [id]. A game saved before its title had company data
  /// may name one of the plain colours instead, which still shows as that
  /// colour.
  Company? companyById(String? id) =>
      Company.byId(id, companies) ?? Company.byId(id);

  /// Builds a title from data imported from tobymao/18xx.
  factory GameTitle.fromData(TitleData data) {
    final sample = data.hexes.first.id;
    final rowShift = data.flat
        ? MapLayout.flatRowShiftFor(sample)
        : MapLayout.rowShiftFor(sample);
    final hexes = <MapHex>[];
    for (final h in data.hexes) {
      final printed = TileDefinition.parseDsl(
          'map:${h.id}', tileColorFromName(h.color), h.code);
      final future = RegExp(r'future_label=label:([^,;]+)').firstMatch(h.code);
      hexes.add(MapHex(
        id: h.id,
        coord: data.flat
            ? MapLayout.coordFromFlatId(h.id, rowShift: rowShift)
            : MapLayout.coordFromId(h.id, rowShift: rowShift),
        printed: printed,
        name: h.name,
        futureLabel: future?.group(1),
      ));
    }
    return GameTitle(
      id: data.id,
      name: data.name,
      description: [
        if (data.location != null) data.location!,
        if (data.designer != null) 'by ${data.designer}',
      ].join(', '),
      map: MapLayout(hexes),
      flat: data.flat,
      trains: [
        for (final t in data.trains)
          TrainType(
            name: t.name,
            base: t.base,
            distance: t.distance,
            pays: t.pays,
            price: t.price,
            rustsOn: t.rustsOn,
            count: t.count,
            freeTowns: t.freeTowns,
            townAllowance: t.townAllowance,
            townsPay: t.townsPay,
            visits: _stopKinds(t.visits),
            paidAt: _stopKinds(t.paidAt),
            multiplier: t.multiplier,
            kind: t.pays != null
                ? TrainKind.express
                : (_hexTrains[data.id]?.call(t.name) ?? false)
                    ? TrainKind.hexes
                    : TrainKind.stops,
          ),
      ],
      phases: [
        for (final p in data.phases)
          GamePhase(
            name: p.name,
            on: p.on,
            trainLimit: p.trainLimit,
            tiles: [for (final t in p.tiles) tileColorFromName(t)],
          ),
      ],
      specialUpgrades: _specialUpgrades[data.id] ?? const {},
      tilesOnlyOn: _tilesOnlyOn[data.id] ?? const {},
      tileStyle: _tileStyles[data.id] ?? TileStyle.plain,
      market: StockMarket.parse(data.market, kind: data.marketKind),
      marketRules: _marketRules[data.id] ?? const MarketRules(),
      doubleSidedTiles: _doubleSided.contains(data.id),
      routeRules: _routeRules[data.id] ?? RouteRules.none,
      stopGroups: {
        for (final h in data.hexes)
          if (_groupsIn(h.code) case final groups when groups.isNotEmpty)
            h.id: groups,
      },
      groupBonus: _bonusesIn(data.hexes),
      tiles: {
        for (final t in data.tiles)
          t.id: TileDefinition.parseDsl(t.id, tileColorFromName(t.color), t.code),
      },
      tileCounts: {for (final t in data.tiles) t.id: ?t.count},
      laidByGame: {
        for (final t in data.tiles)
          if (t.laidByGame) t.id,
      },
      tunnelHexes: data.tunnelHexes.toSet(),
      tunnelTiles: data.tunnelTiles,
      mountainHexes: data.mountainHexes.toSet(),
      mountainPlates: data.mountainTiles,
      companies: data.companies.isEmpty
          ? Company.defaults
          : [
              for (final c in data.companies)
                Company(
                  id: c.id,
                  name: c.name,
                  color: Company.parseColor(c.color),
                  textColor:
                      c.textColor == null ? null : Company.parseColor(c.textColor!),
                  homeHex: c.home,
                  homeCity: c.homeCity,
                  kind: c.kind,
                  tokenCosts: c.tokens,
                  // tobymao's default for a company that doesn't say: a
                  // director's share of 20% and eight of 10%.
                  shares: c.shares.isEmpty
                      ? const [20, 10, 10, 10, 10, 10, 10, 10, 10]
                      : c.shares,
                ),
            ],
    );
  }

  /// The groups a hex's printing puts its stop in: `groups:Stuttgart|N`.
  static Set<String> _groupsIn(String code) {
    final match = RegExp(r'groups:([^,;]+)').firstMatch(code);
    return match == null ? const {} : match.group(1)!.split('|').toSet();
  }

  /// What each off-board area pays towards a bonus, as tobymao works it
  /// out: the figure on its bonus icon (`icon=image:1844/bonus_30`), or for
  /// one printed without, its named group's.
  static Map<String, int> _bonusesIn(List<MapHexData> hexes) {
    int? iconOf(String code) => int.tryParse(
        RegExp(r'icon=image:[^;,]*bonus_(\d+)').firstMatch(code)?.group(1) ??
            '');
    String? namedGroup(String code) =>
        _groupsIn(code).where((g) => g.length > 1).firstOrNull;
    final byGroup = <String, int>{};
    for (final h in hexes) {
      final bonus = iconOf(h.code), group = namedGroup(h.code);
      if (bonus != null && group != null) byGroup[group] = bonus;
    }
    return {
      for (final h in hexes) h.id: ?(iconOf(h.code) ?? byGroup[namedGroup(h.code)]),
    };
  }

  /// A plain rectangular grid with the starter tile set, for boards the app
  /// has no map for.
  factory GameTitle.genericGrid({int rows = 8, int cols = 10}) => GameTitle(
        id: 'generic',
        name: 'Other title',
        description: 'A plain $rows x $cols hex grid and a starter set of '
            'common tiles',
        map: MapLayout.rectangle(rows, cols),
        tiles: {
          for (final e in TileSeedData.all.entries)
            if (e.key != TileSeedData.blankTileId) e.key: e.value,
        },
      );

  /// The kinds of stop tobymao names (`city`, `town`, `offboard`).
  static Set<StationKind>? _stopKinds(List<String>? names) => names == null
      ? null
      : {for (final name in names) ?StationKind.values.asNameMap()[name]};

  static final List<GameTitle> all = [
    GameTitle.fromData(title1807),
    GameTitle.fromData(title1844),
    GameTitle.fromData(title1854),
    GameTitle.fromData(title1880),
    GameTitle.fromData(title1889),
  ];

  static GameTitle? byId(String id) {
    for (final t in all) {
      if (t.id == id) return t;
    }
    return id == 'generic' ? GameTitle.genericGrid() : null;
  }

  /// What's on [coord] as far as track goes: [placed] if a tile is down,
  /// otherwise the printing.
  TileDefinition? contentAt(HexCoord coord, {({String tileId, int rotation})? placed}) {
    if (placed != null) return tiles[placed.tileId]?.rotated(placed.rotation);
    return map.at(coord)?.printed;
  }
}

/// How a train's reach is measured.
enum TrainKind {
  /// So many stops.
  stops,

  /// So many hexes, and off-board areas are out of reach: 1844's H trains.
  hexes,

  /// Any number of stops, paid for the best few: an express.
  express,
}

/// One kind of train in a title.
class TrainType {
  final String name;

  /// The train this is a variant of (`2` for `2H`), or its own name: what
  /// rusting and phases go by.
  final String base;

  final int distance;

  /// For an express, how many stops it is paid for.
  final int? pays;
  final int price;

  /// The train whose arrival scraps this one.
  final String? rustsOn;
  final int count;
  final TrainKind kind;

  /// Whether towns are left out of [distance]: 1854's "+" trains, 1807's.
  final bool freeTowns;

  /// How many towns it runs to besides [distance] without their counting
  /// (1880's "2+2"); [freeTowns] for any number.
  final int townAllowance;

  /// Whether towns pay it: they don't 1807's trains.
  final bool townsPay;

  /// The kinds of stop it may run to -- 1807's goods trains, cities alone
  /// -- or null for any.
  final Set<StationKind>? visits;

  /// The kinds of stop that pay it -- 1807's 5+5E, off-board areas alone
  /// -- or null for every kind.
  final Set<StationKind>? paidAt;

  /// What its route's takings are multiplied by: 1807's "+" trains double
  /// them.
  final int multiplier;

  const TrainType({
    required this.name,
    required this.base,
    required this.distance,
    this.pays,
    this.price = 0,
    this.rustsOn,
    this.count = 0,
    this.kind = TrainKind.stops,
    this.freeTowns = false,
    this.townAllowance = 0,
    this.townsPay = true,
    this.visits,
    this.paidAt,
    this.multiplier = 1,
  });

  @override
  String toString() => name;
}

/// One phase of a title's game.
class GamePhase {
  final String name;

  /// The train whose first sale starts it; null for the first phase.
  final String? on;
  final Map<String, int> trainLimit;
  final List<TileColor> tiles;

  const GamePhase({
    required this.name,
    this.on,
    required this.trainLimit,
    this.tiles = const [],
  });

  /// The most trains a company of [kind] may own in this phase.
  int? limitFor(String? kind) => trainLimit[kind] ?? trainLimit[''];
}

/// Rules for routes that tobymao keeps in a title's game code rather than
/// its data.
class RouteRules {
  /// Whether a route may not stop anywhere that pays nothing: 1844's
  /// mountains before their railway's plate is down, Torino in yellow.
  final bool noEmptyStops;

  /// Added for every stop paid for when a route runs on narrow-gauge track:
  /// 1844's tunnels.
  final int narrowBonus;

  /// Pairs of off-board groups a route earns a bonus for joining: each
  /// group's areas then pay their bonus too (see [GameTitle.groupBonus]).
  final List<(String, String)> bonusPairs;

  const RouteRules({
    this.noEmptyStops = false,
    this.narrowBonus = 0,
    this.bonusPairs = const [],
  });

  static const none = RouteRules();
}
