import 'package:eighteen_scanner/geometry/homography.dart';
import 'package:eighteen_scanner/models/game_session.dart';
import 'package:eighteen_scanner/processing/board_reader.dart';
import 'package:eighteen_scanner/processing/mountain_detector.dart';
import 'package:eighteen_scanner/processing/plate_reader.dart';
import 'package:eighteen_scanner/processing/revenue_ocr.dart';
import 'package:eighteen_scanner/processing/gray_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'support/synthetic_board.dart';

void main() {
  final plates = PlateReader(title).plates;

  test("each plate's figures come from the title, in the order printed", () {
    expect(plates, {
      'XM1': [10, 20, 50, 80],
      'XM2': [10, 40, 50, 60],
      'XM3': [10, 50, 80, 10],
    });
  });

  group('figures', () {
    test('are read as multiples of ten, whatever surrounds them', () {
      // What Vision made of real plates.
      expect(PlateReader.figuresIn('10|40\n50\n60]'), [10, 40, 50, 60]);
      expect(PlateReader.figuresIn('105080 10°'), [10, 50, 80, 10]);
      // A box's border read as a 1.
      expect(PlateReader.figuresIn('110\n150\n80'), [10, 50, 80]);
      expect(PlateReader.figuresIn('(08jos\nOI'), isEmpty);
    });

    test('are placed in the box their word puts them in', () {
      // Vision's words for real plates (see PlateReader.strip): each word
      // and where it lay across the strip.
      expect(
          PlateReader.figuresAt(const [
            RecognizedWord('10/4050|60', 0.0, 0.96),
          ]),
          {0: 10, 1: 40, 2: 50, 3: 60});
      expect(
          PlateReader.figuresAt(const [
            RecognizedWord('(10', 0.02, 0.25),
            RecognizedWord('508010°', 0.28, 0.94),
          ]),
          {0: 10, 1: 50, 2: 80, 3: 10});
      expect(
          PlateReader.figuresAt(const [
            RecognizedWord('10', 0.09, 0.25),
            RecognizedWord('(50(80)', 0.45, 0.93),
          ]),
          {0: 10, 2: 50, 3: 80});
    });

    test('a box read two ways is left unread', () {
      expect(
          PlateReader.agreed([
            {0: 10, 2: 50, 3: 80},
            {2: 50, 3: 60},
          ]),
          {0: 10, 2: 50});
    });
  });

  group('which plate', () {
    test('every box read settles it', () {
      final read = PlateReader.identifyAt({0: 10, 1: 40, 2: 50, 3: 60}, plates);
      expect(read.plate, 'XM2');
      expect(read.sure, isTrue);
    });

    test('some boxes read can still say, but leave it to be checked', () {
      // 10, 50 and 80 alone could be XM1 or XM3; in these boxes, only XM1.
      final read = PlateReader.identifyAt({0: 10, 2: 50, 3: 80}, plates);
      expect(read.plate, 'XM1');
      expect(read.sure, isFalse);
      expect(PlateReader.identify([10, 50, 80], plates).plate, isNull);
    });

    test('figures more than one plate prints, or one alone, say nothing', () {
      expect(PlateReader.identifyAt({0: 10, 2: 50}, plates).plate, isNull);
      expect(PlateReader.identifyAt({1: 40}, plates).plate, isNull);
      expect(PlateReader.identify([50, 80], plates).plate, isNull);
    });

    test('without places, figures in order still say', () {
      expect(PlateReader.identify([10, 50, 80, 10], plates).plate, 'XM3');
      expect(PlateReader.identify([10, 50, 80, 10], plates).sure, isTrue);
      expect(PlateReader.identify([20, 50], plates).plate, 'XM1');
      expect(PlateReader.identify([20, 50], plates).sure, isFalse);
    });
  });

  group('reading a photo', () {
    const radius = 60.0;
    final toImage = boardToDrawn(title.map, radius);
    final pilatus = title.map.byId('G14')!;

    Future<img.Image> board() async {
      final drawn = await drawBoard(title.map, hexRadius: radius);
      drawPlate(drawn, toImage, pilatus);
      underLamp(drawn);
      return drawn;
    }

    MountainReading found(img.Image photo, Homography boardToImage) =>
        BoardReader(title)
            .readMountains(
                photo: photo,
                boardToImage: boardToImage,
                hexes: [pilatus.coord])
            .single;

    /// How yellow, green and red the middle of each quarter of [strip] is,
    /// as the largest of the three.
    List<String> boxColours(img.Image strip) => [
          for (int k = 0; k < 4; k++)
            () {
              // Box k's middle, as the strip lays the boxes out.
              final x = ((0.5 + (k - 1.5) / 4.6) * strip.width).round();
              final p = strip.getPixel(x, strip.height ~/ 2);
              if (p.b < p.r - 60 && p.b < p.g - 60) return 'yellow';
              if (p.g > p.r + 30 && p.g > p.b + 30) return 'green';
              if (p.r > p.g + 30) return 'salmon';
              return 'grey';
            }(),
        ];

    test('the row of boxes is cut out straight, left to right', () async {
      final photo = await board();
      final reading = found(photo, toImage);
      expect(reading.present, isTrue);
      final strip = PlateReader(title)
          .strip(RgbImage.fromImage(photo), toImage, reading)!;
      expect(boxColours(strip), ['yellow', 'green', 'salmon', 'grey']);
    });

    test('and still left to right from a photo taken from the side',
        () async {
      final flat = await board();
      final turned = img.copyRotate(flat, angle: 90);
      final turnedToImage = toImage.then(rotate90(flat));
      final reading = found(turned, turnedToImage);
      expect(reading.present, isTrue);
      final strip = PlateReader(title)
          .strip(RgbImage.fromImage(turned), turnedToImage, reading)!;
      expect(boxColours(strip), ['yellow', 'green', 'salmon', 'grey']);
      expect(strip.width, greaterThan(strip.height));
    });

    test('a plate too small in the photo to read is not tried', () async {
      const small = 36.0;
      final drawn = await drawBoard(title.map, hexRadius: small);
      final smallToImage = boardToDrawn(title.map, small);
      drawPlate(drawn, smallToImage, pilatus);
      underLamp(drawn);
      final reading = found(drawn, smallToImage);
      expect(reading.present, isTrue);
      expect(
          PlateReader(title).strip(
              RgbImage.fromImage(drawn), smallToImage, reading),
          isNull);
    });

    test('what the recognizer reads names the plate', () async {
      final photo = await board();
      final reading = found(photo, toImage);
      final reader = PlateReader(title,
          recognizeWords: (_) async => const [
                RecognizedWord('10', 0.09, 0.25),
                RecognizedWord('(50(80)', 0.45, 0.93),
              ]);
      final read = await reader.readAll(photo, toImage, [reading]);
      expect(read['G14']?.plate, 'XM1');
      expect(read['G14']?.sure, isFalse);
    });

    test('a recognizer that can only read lines reads them in order',
        () async {
      final photo = await board();
      final reading = found(photo, toImage);
      final reader = PlateReader(title,
          recognizeWords: (_) async => throw const TextRecognitionUnavailable(
              'no word positions'),
          recognize: (_) async => '10 40\n50 60');
      final read = await reader.readAll(photo, toImage, [reading]);
      expect(read['G14']?.plate, 'XM2');
      expect(read['G14']?.sure, isTrue);
    });

    test('with no recognizer at all, nothing is read', () async {
      final photo = await board();
      final reading = found(photo, toImage);
      Future<Never> none(img.Image _) async =>
          throw const TextRecognitionUnavailable('none');
      final read = await PlateReader(title,
              recognizeWords: none, recognize: none)
          .readAll(photo, toImage, [reading]);
      expect(read, isEmpty);
    });
  });

  group('into the session', () {
    final pilatus = title.map.byId('G14')!;
    final seen = MountainReading(pilatus, true, 0.9);
    GameSession newGame() =>
        GameSession.start(title: title, name: 'g', startedEmpty: false);

    test('a plate read in full is settled', () {
      final session = newGame();
      BoardReader.applyMountains(session, [seen], plates: {
        'G14': const PlateIdentity('XM2', sure: true, figures: [10, 40, 50, 60]),
      });
      expect(session.mountains['G14'], 'XM2');
      expect(session.mountainDoubts, isEmpty);
    });

    test('a plate read in part is named but left to check', () {
      final session = newGame();
      BoardReader.applyMountains(session, [seen], plates: {
        'G14': const PlateIdentity('XM1', sure: false, figures: [10, 50, 80]),
      });
      expect(session.mountains['G14'], 'XM1');
      expect(session.mountainDoubts, {'G14'});
      // A photo that can't read it keeps the guess.
      BoardReader.applyMountains(session, [seen]);
      expect(session.mountains['G14'], 'XM1');
    });

    test('a plate the user named is not read over', () {
      final session = newGame();
      session.mountains['G14'] = 'XM3';
      BoardReader.applyMountains(session, [seen], plates: {
        'G14': const PlateIdentity('XM2', sure: true, figures: [10, 40, 50, 60]),
      });
      expect(session.mountains['G14'], 'XM3');
    });
  });
}
