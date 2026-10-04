import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:image/image.dart' as img;

import '../models/company.dart';
import '../models/game_title.dart';
import '../models/stock_market.dart';
import 'gray_image.dart';
import 'revenue_ocr.dart';
import 'token_detector.dart';

/// What a photo of the stock market shows: the share value under each
/// company's token, and the market's prices row by row.
class MarketReading {
  /// Each company's share value, where its token was found. A token under
  /// another -- stacked on the same space, as they often are -- isn't seen.
  final Map<String, int> prices;

  /// The prices read, row by row from the top, each left to right: a market
  /// to step along for a title whose market the app doesn't know.
  final List<List<int>> rows;

  const MarketReading({this.prices = const {}, this.rows = const []});

  bool get isEmpty => prices.isEmpty && rows.isEmpty;
}

/// A price printed on the market, where it is in the photo, in pixels.
typedef _Label = ({int price, Offset at, double height});

/// The photo's colour at a point, balanced to its white; null off the photo.
typedef _Sampler = List<double>? Function(Offset at);

/// Reads a photo of a title's stock market. Every space prints its price
/// near its top left, so the prices the platform reads give the market's
/// rows and columns in the photo; lined up with the title's market -- or,
/// where it isn't known, taken as the market -- they place every space,
/// even one whose price a token hides. Each space is then looked at for a
/// token: a disc of colour unlike the space's own paper. Each company's
/// token is the space whose colour is nearest its own, a company to a
/// space. A rough start for the share values, for the user to put right.
class MarketReader {
  final GameTitle title;

  const MarketReader(this.title);

  MarketReading read(List<RecognizedWord> lines, img.Image photo) {
    final labels = _largest(_labelsIn(lines, photo));
    final rows = _rowsOf(labels);
    if (rows.isEmpty) return const MarketReading();
    final read = [
      for (final row in rows) [for (final l in row) l.price],
    ];
    // Where each label is on the market, and so where each space is in the
    // photo.
    final market = title.market.isEmpty
        ? StockMarket([
            for (final row in read) [for (final p in row) MarketCell(p)],
          ])
        : title.market;
    final placed = _place(rows, market, ownRows: title.market.isEmpty);
    if (placed.length < 4) return MarketReading(rows: read);
    final fit = _Affine.fit([
      for (final (spot, label) in placed)
        ((spot.col.toDouble(), spot.row.toDouble()), label.at),
    ]);
    if (fit == null) return MarketReading(rows: read);
    final cellWidth = (fit.apply(1, 0) - fit.apply(0, 0)).distance;
    // A camera's lens bends a market a little, more than one straight fit
    // follows: each space is put right by how far off the fit the nearest
    // prices read were.
    final residuals = [
      for (final (spot, label) in placed)
        (spot, label.at - fit.apply(spot.col.toDouble(), spot.row.toDouble())),
    ];
    Offset where(double col, double row) {
      final nearest = [...residuals]..sort((a, b) =>
          ((a.$1.col - col).abs() + (a.$1.row - row).abs())
              .compareTo((b.$1.col - col).abs() + (b.$1.row - row).abs()));
      var sum = Offset.zero;
      var weights = 0.0;
      for (final (spot, off) in nearest.take(4)) {
        final w = 1 / (1 + (spot.col - col).abs() + (spot.row - row).abs());
        sum += off * w;
        weights += w;
      }
      return fit.apply(col, row) + sum / weights;
    }

    final rgb = RgbImage.fromImage(photo);
    final white = _whiteOf(rgb);
    final sample = List<double>.filled(3, 0);
    List<double>? at(Offset p) {
      if (!rgb.contains(p.dx, p.dy)) return null;
      rgb.sample(p.dx, p.dy, sample);
      return [for (int k = 0; k < 3; k++) 255 * sample[k] / white[k]];
    }

    // The paper of each zone of the market -- spaces printed alike, by the
    // letters after their prices (`y`, `o`, a par price's `p`) -- from all
    // its spaces, so one space whose sample went astray doesn't count.
    final spots = [
      for (int r = 0; r < market.rows.length; r++)
        for (int c = 0; c < market.rows[r].length; c++)
          if (market.rows[r][c] != null) (row: r, col: c),
    ];
    final papers = <String, List<List<double>>>{};
    for (final spot in spots) {
      final paper = _paperOf(at, where, spot, cellWidth);
      if (paper != null) {
        papers.putIfAbsent(market.at(spot)!.types, () => []).add(paper);
      }
    }
    final zonePaper = {
      for (final e in papers.entries) e.key: _median(e.value),
    };

    // Each space looked at for a token.
    final seen = <(MarketSpot, List<double>)>[];
    for (final spot in spots) {
      final paper = zonePaper[market.at(spot)!.types];
      if (paper == null) continue;
      final colour = _tokenIn(at, where, spot, cellWidth, paper);
      if (colour != null) seen.add((spot, colour));
    }
    // A company to a space: the nearest colours first.
    final pairs = <(double, Company, MarketSpot)>[
      for (final company in title.companies)
        if (company.kind != 'minor')
          for (final (spot, colour) in seen)
            (TokenDetector.colourDistance(colour, company.color), company, spot),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final prices = <String, int>{};
    final taken = <MarketSpot>{};
    for (final (distance, company, spot) in pairs) {
      if (distance > _near) break;
      if (prices.containsKey(company.id) || taken.contains(spot)) continue;
      prices[company.id] = market.at(spot)!.price;
      taken.add(spot);
    }
    return MarketReading(prices: prices, rows: read);
  }

  /// The prices in [lines], each where it is printed. A recognizer may run a
  /// row's prices into one line ("100 110 120"), so each figure of a line of
  /// figures is placed along it by its share of the letters.
  static List<_Label> _labelsIn(List<RecognizedWord> lines, img.Image photo) {
    final w = photo.width.toDouble(), h = photo.height.toDouble();
    final labels = <_Label>[];
    for (final line in lines) {
      final words = line.text.trim().split(RegExp(r'\s+'));
      final figures = [for (final word in words) _priceIn(word)];
      if (words.isEmpty || figures.any((f) => f == null)) continue;
      final letters =
          words.fold(0, (total, word) => total + word.length) + words.length - 1;
      var start = 0;
      for (int i = 0; i < words.length; i++) {
        final from = line.left + line.width * start / letters;
        final to = line.left + line.width * (start + words[i].length) / letters;
        labels.add((
          price: figures[i]!,
          at: Offset((from + to) / 2 * w, (line.top + line.bottom) / 2 * h),
          height: line.height * h,
        ));
        start += words[i].length + 1;
      }
    }
    return labels;
  }

  /// The price [word] is, if it is one: a figure of two to four digits,
  /// perhaps with a currency or a stray mark beside it.
  static int? _priceIn(String word) {
    final match = RegExp(r'^[^\d]{0,2}(\d{2,4})[^\d]{0,2}$').firstMatch(word);
    return match == null ? null : int.parse(match[1]!);
  }

  /// The spaces' own prices, printed large, without the small ones some
  /// markets print again in a corner.
  static List<_Label> _largest(List<_Label> labels) {
    if (labels.isEmpty) return labels;
    final heights = [for (final l in labels) l.height]..sort();
    final large = heights[(heights.length * 3) ~/ 4];
    return [
      for (final l in labels)
        if (l.height >= large * 0.75) l,
    ];
  }

  /// [labels] in rows, top to bottom, each left to right: each label joined
  /// to the next along to its right at about its height, so a row a little
  /// askew in the photo still holds together.
  static List<List<_Label>> _rowsOf(List<_Label> labels) {
    if (labels.isEmpty) return const [];
    final heights = [for (final l in labels) l.height]..sort();
    final height = heights[heights.length ~/ 2];
    final parent = List<int>.generate(labels.length, (i) => i);
    int find(int i) => parent[i] == i ? i : parent[i] = find(parent[i]);
    for (int i = 0; i < labels.length; i++) {
      int? next;
      var nearest = double.infinity;
      for (int j = 0; j < labels.length; j++) {
        final dx = labels[j].at.dx - labels[i].at.dx;
        final dy = (labels[j].at.dy - labels[i].at.dy).abs();
        if (dx <= height || dy > height * 0.6 || dx >= nearest) continue;
        nearest = dx;
        next = j;
      }
      if (next != null) parent[find(next)] = find(i);
    }
    final groups = <int, List<_Label>>{};
    for (int i = 0; i < labels.length; i++) {
      groups.putIfAbsent(find(i), () => []).add(labels[i]);
    }
    final rows = [
      for (final row in groups.values)
        if (row.length >= 2) row..sort((a, b) => a.at.dx.compareTo(b.at.dx)),
    ]..sort((a, b) => _meanY(a).compareTo(_meanY(b)));
    return rows;
  }

  static double _meanY(List<_Label> row) =>
      row.fold(0.0, (total, l) => total + l.at.dy) / row.length;

  /// Where on [market] each label read in [rows] is. Columns are counted
  /// from each label's place across the photo, a space's width apart; the
  /// photo's columns are laid over the market's where most prices agree, and
  /// each row of the photo goes with the market row its prices match --
  /// one each, so a stray row of small print can't put the rest out. With
  /// [ownRows] the market is the photo's own rows, as read.
  static List<(MarketSpot, _Label)> _place(
      List<List<_Label>> rows, StockMarket market, {required bool ownRows}) {
    if (ownRows) {
      return [
        for (int r = 0; r < rows.length; r++)
          for (int c = 0; c < rows[r].length; c++) ((row: r, col: c), rows[r][c]),
      ];
    }
    final gaps = [
      for (final row in rows)
        for (int i = 1; i < row.length; i++) row[i].at.dx - row[i - 1].at.dx,
    ]..sort();
    if (gaps.isEmpty) return const [];
    final width = gaps[gaps.length ~/ 2];
    final left = rows.map((row) => row.first.at.dx).reduce(math.min);
    final columns = [
      for (final row in rows)
        [for (final l in row) ((l.at.dx - left) / width).round()],
    ];
    final widest = market.rows.fold(0, (most, r) => math.max(most, r.length));
    final across = columns.expand((c) => c).fold(0, math.max);
    var best = <(MarketSpot, _Label)>[];
    for (int dc = -across; dc <= widest; dc++) {
      // Each photo row's best market row at this lie of the columns.
      final byMarketRow = <int, List<(MarketSpot, _Label)>>{};
      for (int r = 0; r < rows.length; r++) {
        var rowBest = <(MarketSpot, _Label)>[];
        var rowAt = -1;
        for (int mr = 0; mr < market.rows.length; mr++) {
          final matched = <(MarketSpot, _Label)>[];
          for (int i = 0; i < rows[r].length; i++) {
            final spot = (row: mr, col: columns[r][i] + dc);
            if (market.at(spot)?.price == rows[r][i].price) {
              matched.add((spot, rows[r][i]));
            }
          }
          if (matched.length > rowBest.length) {
            rowBest = matched;
            rowAt = mr;
          }
        }
        if (rowBest.length < 2 || rowBest.length * 2 < rows[r].length) continue;
        final before = byMarketRow[rowAt];
        if (before == null || rowBest.length > before.length) {
          byMarketRow[rowAt] = rowBest;
        }
      }
      final matched = [for (final m in byMarketRow.values) ...m];
      if (matched.length > best.length) best = matched;
    }
    return best;
  }

  /// The paper the space at [spot] is printed on: a patch below its price,
  /// at the space's left, where a token isn't put -- it goes beside the
  /// price -- nor the space's price printed again. Null where too little
  /// of it is in the photo.
  static List<double>? _paperOf(_Sampler at, Offset Function(double, double) where,
      MarketSpot spot, double cellWidth) {
    final patch = <List<double>>[];
    for (double dc = -0.04; dc <= 0.08; dc += 0.04) {
      for (double dr = 0.36; dr <= 0.5; dr += 0.07) {
        final c = at(where(spot.col + dc, spot.row + dr));
        if (c != null) patch.add(c);
      }
    }
    return patch.length < 6 ? null : _median(patch);
  }

  /// The colour of a token on the space at [spot], if one is there: most of
  /// a ring about the middle of a disc beside and below the space's price --
  /// where a token is put, the price showing past it -- unlike [paper]; the
  /// ring, because the middle of a token is its logo, often pale. And it is
  /// a disc: past its edge the colour doesn't carry on, as a coloured space's
  /// own would. The token's colour is the middle of the ring's samples.
  static List<double>? _tokenIn(_Sampler at, Offset Function(double, double) where,
      MarketSpot spot, double cellWidth, List<double> paper) {
    final middle = where(spot.col + 0.42, spot.row + 0.32);
    List<List<double>> ring(double radius, int steps) => [
          for (int a = 0; a < steps; a++)
            ?at(middle +
                Offset(math.cos(a * 2 * math.pi / steps),
                        math.sin(a * 2 * math.pi / steps)) *
                    (cellWidth * radius)),
        ];
    final rim = [...ring(0.13, 12), ...ring(0.19, 16), ...ring(0.24, 16)];
    if (rim.length < 30) return null;
    final unlike = [
      for (final c in rim)
        if (_distance(c, paper) > _unlikePaper) c,
    ];
    if (unlike.length < rim.length * 0.5) return null;
    final colour = _median(unlike);
    final outside = ring(0.4, 16);
    final carriesOn =
        outside.where((c) => _distance(c, colour) < _unlikePaper).length;
    if (outside.isEmpty || carriesOn > outside.length * 0.4) return null;
    return colour;
  }

  static double _distance(List<double> a, List<double> b) => math.sqrt(
      math.pow(a[0] - b[0], 2) + math.pow(a[1] - b[1], 2) + math.pow(a[2] - b[2], 2));

  static List<double> _median(List<List<double>> colours) => [
        for (int k = 0; k < 3; k++)
          (colours.map((c) => c[k]).toList()..sort())[colours.length ~/ 2],
      ];

  /// How far from a space's paper a sample has to be to be taken for a
  /// token, in white-balanced red, green and blue.
  static const double _unlikePaper = 40;

  /// How far a token's colour may be from a company's and still be taken
  /// for its token, in the token detector's colour distance.
  static const double _near = 120;

  /// The photo's white: the brightest few percent of it, which on a stock
  /// market is its paper.
  static List<double> _whiteOf(RgbImage photo) {
    final samples = <List<double>>[];
    final rgb = List<double>.filled(3, 0);
    final step = math.max(1, math.min(photo.width, photo.height) ~/ 60);
    for (int y = 0; y < photo.height; y += step) {
      for (int x = 0; x < photo.width; x += step) {
        photo.sample(x.toDouble(), y.toDouble(), rgb);
        samples.add(List.of(rgb));
      }
    }
    if (samples.isEmpty) return const [255, 255, 255];
    samples.sort((a, b) => (b[0] + b[1] + b[2]).compareTo(a[0] + a[1] + a[2]));
    final top = samples.take(math.max(1, samples.length ~/ 33)).toList();
    return [
      for (int k = 0; k < 3; k++)
        math.max(1.0, (top.map((c) => c[k]).toList()..sort())[top.length ~/ 2]),
    ];
  }
}

/// An affine map from a market's columns and rows to the photo, fitted to
/// where its prices were read.
class _Affine {
  final double a, b, c, d, e, f;

  const _Affine(this.a, this.b, this.c, this.d, this.e, this.f);

  Offset apply(double col, double row) =>
      Offset(a * col + b * row + c, d * col + e * row + f);

  /// The least-squares fit of [pairs] of (column, row) and where in the
  /// photo; null if they don't pin one down.
  static _Affine? fit(List<((double, double), Offset)> pairs) {
    // Normal equations for x = a col + b row + c (and y likewise).
    final m = List.generate(3, (_) => List<double>.filled(3, 0));
    final vx = List<double>.filled(3, 0), vy = List<double>.filled(3, 0);
    for (final ((col, row), at) in pairs) {
      final v = [col, row, 1.0];
      for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) {
          m[i][j] += v[i] * v[j];
        }
        vx[i] += v[i] * at.dx;
        vy[i] += v[i] * at.dy;
      }
    }
    final x = _solve(m, vx), y = _solve(m, vy);
    if (x == null || y == null) return null;
    return _Affine(x[0], x[1], x[2], y[0], y[1], y[2]);
  }

  static List<double>? _solve(List<List<double>> m, List<double> v) {
    final a = [
      for (int i = 0; i < 3; i++) [...m[i], v[i]],
    ];
    for (int i = 0; i < 3; i++) {
      var pivot = i;
      for (int r = i + 1; r < 3; r++) {
        if (a[r][i].abs() > a[pivot][i].abs()) pivot = r;
      }
      if (a[pivot][i].abs() < 1e-9) return null;
      final swap = a[i];
      a[i] = a[pivot];
      a[pivot] = swap;
      for (int r = 0; r < 3; r++) {
        if (r == i) continue;
        final k = a[r][i] / a[i][i];
        for (int c = i; c < 4; c++) {
          a[r][c] -= k * a[i][c];
        }
      }
    }
    return [for (int i = 0; i < 3; i++) a[i][3] / a[i][i]];
  }
}
