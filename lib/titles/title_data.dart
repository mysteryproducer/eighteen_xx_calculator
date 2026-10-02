/// Raw per-title data as imported from tobymao/18xx by
/// `tool/import_tobymao_title.dart`: the printed map and the tile manifest,
/// both in that project's tile DSL. `GameTitle` turns this into the parsed
/// map and tile definitions the app works with.
class TitleData {
  final String id;
  final String name;
  final String? location;
  final String? designer;
  final List<MapHexData> hexes;
  final List<TileData> tiles;
  final List<CompanyData> companies;

  /// The trains, and the phases they bring.
  final List<TrainData> trains;
  final List<PhaseData> phases;

  /// Whether the map is printed with flat-topped hexes (1889's is) rather
  /// than pointy-topped ones; its coordinates are then column letter and
  /// row number.
  final bool flat;

  /// Hexes a tunnel can be driven through, and the tiles whose narrow
  /// track shows which ways a tunnel can run (1844's).
  final List<String> tunnelHexes;
  final List<String> tunnelTiles;

  /// Mountains a mountain railway's revenue plate can be assigned to, and
  /// the plates (1844's).
  final List<String> mountainHexes;
  final List<String> mountainTiles;

  const TitleData({
    required this.id,
    required this.name,
    required this.location,
    required this.designer,
    required this.hexes,
    required this.tiles,
    this.companies = const [],
    this.trains = const [],
    this.phases = const [],
    this.flat = false,
    this.tunnelHexes = const [],
    this.tunnelTiles = const [],
    this.mountainHexes = const [],
    this.mountainTiles = const [],
  });
}

/// One printed map hex. [id] is the coordinate printed on the board, a row
/// letter and a column number (`D19`); [color] is tobymao's colour name.
class MapHexData {
  final String id;
  final String color;
  final String code;
  final String? name;

  const MapHexData(this.id, this.color, this.code, {this.name});
}

/// One tile design in the title's manifest, and how many copies come in the
/// box.
class TileData {
  final String id;
  final String color;
  final String code;
  final int count;

  /// True for tiles the game lays by itself rather than a player choosing
  /// them: 1844's Gotthard tunnel tiles, which appear when the line opens.
  final bool laidByGame;

  const TileData(this.id, this.color, this.code,
      {required this.count, this.laidByGame = false});
}

/// A company that puts station tokens on the board: its token colour (and
/// the colour of the lettering on it) as tobymao's colour names or `#rrggbb`,
/// and the hex and city its home token goes in, if it has one.
class CompanyData {
  final String id;
  final String name;
  final String color;
  final String? textColor;
  final String? home;
  final int? homeCity;

  /// tobymao's kind of company (`major`, `minor`, `pre-sbb`...).
  final String? kind;

  /// What each of the company's station tokens costs to lay, the home
  /// token's first; and the share certificates it is divided into, as
  /// percentages, the director's first.
  final List<int> tokens;
  final List<int> shares;

  const CompanyData(this.id, this.name, this.color,
      {this.textColor,
      this.home,
      this.homeCity,
      this.kind,
      this.tokens = const [],
      this.shares = const []});
}

/// One kind of train, as the title lists it.
class TrainData {
  final String name;

  /// How far it runs: stops (hexes for some titles' trains, see
  /// `GameTitle`), or for an express how many stops it may visit.
  final int distance;

  /// For an express -- which visits any number of stops and is paid for
  /// the best few -- how many are paid for. Null for other trains.
  final int? pays;

  final int price;

  /// The train whose arrival scraps this one.
  final String? rustsOn;

  /// The train this is a variant of (`2` for `2H`), or its own name.
  final String base;

  /// How many there are.
  final int count;

  /// Whether towns are left out of [distance] and all paid for: 1854's
  /// "+" trains, which run to so many cities and any number of towns.
  final bool freeTowns;

  const TrainData(this.name,
      {required this.distance,
      this.pays,
      this.freeTowns = false,
      this.price = 0,
      this.rustsOn,
      String? base,
      this.count = 0})
      : base = base ?? name;
}

/// One phase of the game.
class PhaseData {
  final String name;

  /// The train whose first sale starts it; null for the first.
  final String? on;

  /// The most trains a company may own, by kind of company; under '' for
  /// every kind.
  final Map<String, int> trainLimit;

  /// The colours of tile that can be laid.
  final List<String> tiles;

  const PhaseData(this.name,
      {this.on, required this.trainLimit, this.tiles = const []});
}
