import 'dart:io';
import 'dart:ui';

import 'package:eighteen_scanner/models/game_title.dart';
import 'package:eighteen_scanner/processing/market_reader.dart';
import 'package:eighteen_scanner/processing/revenue_ocr.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// [colour] as a token of it photographs: paler, as `TokenDetector`
/// expects of a card token under a lamp.
img.Color photographed(Color colour) {
  int pale(double c) => (255 - 0.6 * (255 - c * 255)).round();
  return img.ColorRgb8(pale(colour.r), pale(colour.g), pale(colour.b));
}

void main() {
  final g1889 = GameTitle.byId('1889')!;
  Color colourOf(String id) => g1889.companyById(id)!.color;

  // The top three rows of 1889's market, six spaces of each, a space 100
  // pixels across: each price near its space's top left, a token beside it
  // and below, as they are put.
  const rows = [
    [75, 80, 90, 100, 110, 125],
    [70, 75, 80, 90, 100, 110],
    [65, 70, 75, 80, 90, 100],
  ];
  const width = 700, height = 400;
  Offset label(int row, int col) => Offset(50.0 + col * 100 + 22, 40.0 + row * 100 + 18);

  img.Image market({Map<String, (int, int)> tokens = const {}}) {
    final photo = img.Image(width: width, height: height);
    img.fill(photo, color: img.ColorRgb8(250, 250, 250));
    tokens.forEach((id, at) {
      final (row, col) = at;
      final centre = label(row, col) + const Offset(42, 32);
      img.fillCircle(photo,
          x: centre.dx.round(),
          y: centre.dy.round(),
          radius: 30,
          color: photographed(colourOf(id)));
    });
    return photo;
  }

  /// The prices as a recognizer reads them, but for those under [hidden].
  List<RecognizedWord> printed({Set<(int, int)> hidden = const {}}) => [
        for (int r = 0; r < rows.length; r++)
          for (int c = 0; c < rows[r].length; c++)
            if (!hidden.contains((r, c)))
              RecognizedWord(
                '${rows[r][c]}',
                (label(r, c).dx - 15) / width,
                (label(r, c).dx + 15) / width,
                top: (label(r, c).dy - 10) / height,
                bottom: (label(r, c).dy + 10) / height,
              ),
      ];

  test("each company's token read as the price of the space it is on", () {
    final reading = MarketReader(g1889).read(
      printed(),
      market(tokens: {'AR': (0, 2), 'IR': (1, 4)}),
    );
    expect(reading.prices, {'AR': 90, 'IR': 100});
    expect(reading.rows, rows);
  });

  test("a price a token hides is the market's for the space", () {
    // Iyo's token covers its space's price; the market says it is 80.
    final reading = MarketReader(g1889).read(
      printed(hidden: {(1, 2)}),
      market(tokens: {'IR': (1, 2)}),
    );
    expect(reading.prices, {'IR': 80});
  });

  test("a title whose market isn't known: the prices read are the market",
      () {
    final unknown = GameTitle(
      id: 'unknown',
      name: 'Unknown',
      description: '',
      map: g1889.map,
      tiles: const {},
      companies: g1889.companies,
    );
    final reading = MarketReader(unknown).read(
      printed(),
      market(tokens: {'UR': (2, 3)}),
    );
    expect(reading.rows, rows);
    expect(reading.prices, {'UR': 80});
  });

  test('a photo with no prices read finds nothing', () {
    final reading =
        MarketReader(g1889).read(const [], market(tokens: {'AR': (0, 1)}));
    expect(reading.isEmpty, isTrue);
  });

  final root = Platform.environment['DATASET_DIR'];

  /// The lines Vision read in a dataset photo, saved beside it.
  List<RecognizedWord> linesIn(String path) => [
        for (final l in File('$root/$path').readAsLinesSync())
          if (l.trim().isNotEmpty)
            () {
              final n = l
                  .substring(0, l.indexOf('  '))
                  .split(' ')
                  .map(double.parse)
                  .toList();
              return RecognizedWord(l.substring(l.indexOf('  ') + 2), n[0], n[2],
                  top: n[1], bottom: n[3]);
            }(),
      ];

  // The webcam's photo of 1889's market (4 October), with Vision's lines:
  // six tokens to be seen, Tosa Kuroshio's hidden under Awa's.
  test('the real photo of 1889\'s market', () {
    final photo = img.decodePng(
        File('$root/photos/webcam/board_1791104709133.png').readAsBytesSync())!;
    final reading = MarketReader(g1889)
        .read(linesIn('photos/webcam/board_1791104709133.ocr.txt'), photo);
    expect(reading.prices['IR'], 255);
    expect(reading.prices['KO'], 175);
    expect(reading.prices['SR'], 110);
    expect(reading.prices['AR'], 110);
    expect(reading.prices['UR'], 75);
  }, skip: root == null ? 'Set DATASET_DIR' : false);

  // The same market on the Nokia C32 the same day, photographed sideways and
  // read turned upright, as the pipeline turns it: all six to be seen.
  test('the real photo of 1889\'s market, sideways', () {
    final photo = img.copyRotate(
        img.decodeJpg(File('$root/photos/phone-nokia-c32/'
                'CAP1127909214376585085.jpg')
            .readAsBytesSync())!,
        angle: 270);
    final reading = MarketReader(g1889).read(
        linesIn('photos/phone-nokia-c32/'
            'CAP1127909214376585085.turned270.ocr.txt'),
        photo);
    expect(reading.prices, {
      'IR': 255,
      'KO': 175,
      'SR': 110,
      'TR': 110,
      'AR': 110,
      'UR': 75,
    });
  }, skip: root == null ? 'Set DATASET_DIR' : false);
}
