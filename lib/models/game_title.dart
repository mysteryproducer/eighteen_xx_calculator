import '../titles/title_1844.dart';
import '../titles/title_1854.dart';
import '../titles/title_data.dart';
import 'board.dart';
import 'company.dart';
import 'map_layout.dart';
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

  /// How many of each tile come in the box.
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
  });

  /// The company with [id]. A game saved before its title had company data
  /// may name one of the plain colours instead, which still shows as that
  /// colour.
  Company? companyById(String? id) =>
      Company.byId(id, companies) ?? Company.byId(id);

  /// Builds a title from data imported from tobymao/18xx.
  factory GameTitle.fromData(TitleData data) {
    final rowShift = MapLayout.rowShiftFor(data.hexes.first.id);
    final hexes = <MapHex>[];
    for (final h in data.hexes) {
      final printed = TileDefinition.parseDsl(
          'map:${h.id}', tileColorFromName(h.color), h.code);
      final future = RegExp(r'future_label=label:([^,;]+)').firstMatch(h.code);
      hexes.add(MapHex(
        id: h.id,
        coord: MapLayout.coordFromId(h.id, rowShift: rowShift),
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
      tiles: {
        for (final t in data.tiles)
          t.id: TileDefinition.parseDsl(t.id, tileColorFromName(t.color), t.code),
      },
      tileCounts: {for (final t in data.tiles) t.id: t.count},
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
                ),
            ],
    );
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

  static final List<GameTitle> all = [
    GameTitle.fromData(title1844),
    GameTitle.fromData(title1854),
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
