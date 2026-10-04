/// One cell of a title's stock market: its price, and what the cell does, by
/// tobymao's letters after the price (`p`, a par price; `y`, `o` and `b`,
/// zones; `t`, out of bounds to some kinds of company; `c`, the company
/// closes).
class MarketCell {
  final int price;
  final String types;

  const MarketCell(this.price, [this.types = '']);

  /// The cell tobymao writes as [code] (`100p`), or null for no cell (`''`).
  static MarketCell? parse(String code) {
    final match = RegExp(r'^(\d+)(.*)$').firstMatch(code.trim());
    return match == null
        ? null
        : MarketCell(int.parse(match[1]!), match[2]!);
  }

  @override
  String toString() => '$price$types';
}

/// How a price moves on a market: see [StockMarket.right].
enum MarketKind { grid, hex, row }

/// A place on a market: its row and column.
typedef MarketSpot = ({int row, int col});

/// A title's stock market, and how a company's share price moves on it --
/// as tobymao moves it (`lib/engine/stock_movement.rb`).
class StockMarket {
  final List<List<MarketCell?>> rows;
  final MarketKind kind;

  const StockMarket(this.rows, {this.kind = MarketKind.grid});

  /// The market tobymao writes as [rows] of cells (see [MarketCell.parse]);
  /// [kind] as `GameTitle` has it: `grid`, `hex` or `row`.
  factory StockMarket.parse(List<List<String>> rows, {String kind = 'grid'}) =>
      StockMarket([
        for (final row in rows) [for (final code in row) MarketCell.parse(code)],
      ], kind: MarketKind.values.asNameMap()[kind] ?? MarketKind.grid);

  bool get isEmpty => rows.isEmpty;

  /// The cell at [spot], or null where there is none.
  MarketCell? at(MarketSpot spot) => spot.row < 0 ||
          spot.row >= rows.length ||
          spot.col < 0 ||
          spot.col >= rows[spot.row].length
      ? null
      : rows[spot.row][spot.col];

  /// Where a share priced [price] sits: the top-most of the cells priced so,
  /// whose row runs furthest. On these markets the prices to the right of a
  /// price are the same from whichever row it is in, up to the row's end,
  /// where a price moves up into the row above. Null if no cell is.
  MarketSpot? find(int price) {
    for (int r = 0; r < rows.length; r++) {
      for (int c = 0; c < rows[r].length; c++) {
        if (rows[r][c]?.price == price) return (row: r, col: c);
      }
    }
    return null;
  }

  /// One space right, as a dividend moves a price: along the row; off the
  /// end of a grid's row, up a row; off the end of a hex market's row,
  /// diagonally up; along a single row, no further than its end.
  MarketSpot right(MarketSpot spot) {
    final next = (row: spot.row, col: spot.col + 1);
    return switch (kind) {
      MarketKind.row => at(next) == null ? spot : next,
      MarketKind.grid =>
        spot.col + 1 < rows[spot.row].length ? next : up(spot),
      MarketKind.hex => at(next) == null ? up(spot) : next,
    };
  }

  /// One space left, as a withheld dividend moves a price: along the row;
  /// off its start, down a row -- or, on a hex market, diagonally down.
  MarketSpot left(MarketSpot spot) {
    final previous = (row: spot.row, col: spot.col - 1);
    return switch (kind) {
      MarketKind.row => at(previous) == null ? spot : previous,
      MarketKind.grid || MarketKind.hex =>
        at(previous) == null ? down(spot) : previous,
    };
  }

  /// One space up, where there is a cell above; on a single row, right.
  MarketSpot up(MarketSpot spot) {
    if (kind == MarketKind.row) return right(spot);
    final above = (row: spot.row - 1, col: spot.col);
    return at(above) == null ? spot : above;
  }

  /// One space down, where there is a cell below; on a single row, left.
  MarketSpot down(MarketSpot spot) {
    if (kind == MarketKind.row) return left(spot);
    final below = (row: spot.row + 1, col: spot.col);
    return at(below) == null ? spot : below;
  }
}

/// How a title's share prices move when a company pays out, and what its
/// minors pay their owners: tobymao's, from each game's code.
class MarketRules {
  /// How far a payout moves the share price: for a payout of at least each
  /// multiple of the price, so many spaces right -- or left, where negative
  /// -- the largest multiple reached counting. A payout below the first
  /// multiple doesn't move it. tobymao's default: anything paid, one space
  /// right; some games jump two, three or four for larger payouts.
  final List<(double, int)> payoutMoves;

  /// How many spaces left a company that pays nothing moves.
  final int withholdMoves;

  /// Cells, by their letter, that companies of the kinds given can't move
  /// right into, going up instead: 1844's regional companies and its `t`
  /// cells.
  final Map<String, Set<String>> barred;

  /// What share of a minor company's takings its owner is paid: all of them
  /// by tobymao's default, half in 1854 and 1807, none of what 1880's
  /// foreign investors earn.
  final double minorPayout;

  const MarketRules({
    this.payoutMoves = const [(0.0, 1)],
    this.withholdMoves = 1,
    this.barred = const {},
    this.minorPayout = 1,
  });

  /// How many spaces right (negative: left) paying out [paid] in all moves
  /// a share priced [price].
  int movesFor(int paid, int price) {
    if (paid <= 0) return -withholdMoves;
    var moves = 0;
    for (final (multiple, spaces) in payoutMoves) {
      if (paid >= multiple * price) moves = spaces;
    }
    return moves;
  }

  /// Where a share of a company of [kind] at [spot] on [market] goes when a
  /// payout of [paid] moves it, priced [price] as it is.
  MarketSpot move(StockMarket market, MarketSpot spot,
      {required int paid, required int price, String? kind}) {
    final moves = movesFor(paid, price);
    var at = spot;
    for (int i = 0; i < moves.abs(); i++) {
      if (moves < 0) {
        at = market.left(at);
        continue;
      }
      final next = market.right(at);
      final cell = market.at(next);
      final barredHere = cell != null &&
          barred.entries.any((e) =>
              cell.types.contains(e.key) && e.value.contains(kind));
      at = barredHere ? market.up(at) : next;
    }
    return at;
  }
}
