import 'package:eighteen_scanner/geometry/homography.dart';
import 'package:eighteen_scanner/models/company.dart';
import 'package:eighteen_scanner/models/game_title.dart';
import 'package:eighteen_scanner/processing/gray_image.dart';
import 'package:eighteen_scanner/processing/revenue_ocr.dart';
import 'package:eighteen_scanner/processing/token_detector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Board units to pixels for the pictures below: a hex's radius is 100.
final boardToImage = Homography.similarity(scale: 100);

/// Where the slot is, in board units, and its radius.
const slot = Offset(1, 1);
const slotRadius = 0.25;

/// A patch of board with one city slot on it: beige map, the white slot
/// with its black ring, a white revenue bubble beside it, and optionally a
/// token -- a disc of [token] colour with a dark logo in its middle -- or a
/// printed [logo] on the white. [light] tints everything, as a lamp does.
RgbImage slotPhoto({
  Color? token,
  bool logo = false,
  Color? printed,
  Color light = Colors.white,
}) {
  final image = img.Image(width: 200, height: 200);
  img.ColorRgb8 lit(int r, int g, int b) => img.ColorRgb8(
        (r * light.r).round(),
        (g * light.g).round(),
        (b * light.b).round(),
      );
  img.fill(image, color: lit(222, 205, 170));
  img.fillCircle(image, x: 160, y: 40, radius: 14, color: lit(255, 255, 255));
  img.fillCircle(image, x: 100, y: 100, radius: 27, color: lit(20, 20, 20));
  img.fillCircle(image, x: 100, y: 100, radius: 25, color: lit(255, 255, 255));
  if (printed != null) {
    img.fillCircle(image,
        x: 100,
        y: 100,
        radius: 23,
        color: lit((printed.r * 255).round(), (printed.g * 255).round(),
            (printed.b * 255).round()));
  }
  if (token != null) {
    img.fillCircle(image,
        x: 102,
        y: 99,
        radius: 23,
        color: lit((token.r * 255).round(), (token.g * 255).round(),
            (token.b * 255).round()));
  }
  if (logo || token != null) {
    img.fillRect(image, x1: 95, y1: 94, x2: 108, y2: 106, color: lit(40, 35, 30));
  }
  return RgbImage.fromImage(image);
}

TokenDetection look(
  RgbImage photo, {
  required bool onTile,
  Company? home,
  List<Company> companies = Company.defaults,
}) =>
    TokenDetector(companies: companies).detect(
      photo: photo,
      boardToImage: boardToImage,
      slot: slot,
      slotRadius: slotRadius,
      white: TokenDetector.localWhite(photo, boardToImage, slot),
      onTile: onTile,
      home: home,
    );

void main() {
  group('station tokens', () {
    final red = Company.defaults.firstWhere((c) => c.id == 'red');
    final blue = Company.defaults.firstWhere((c) => c.id == 'blue');
    final title1844 = GameTitle.byId('1844')!;
    final bls = title1844.companyById('BLS')!;
    final gb = title1844.companyById('GB')!;

    test('an empty slot on a tile reads as empty', () {
      final seen = look(slotPhoto(), onTile: true);
      expect(seen.present, isFalse);
      expect(seen.confidence, greaterThan(0.5));
    });

    test('a token on a tile is seen, and whose it is told by its colour', () {
      final seenRed = look(slotPhoto(token: red.color), onTile: true);
      expect(seenRed.present, isTrue);
      expect(seenRed.company?.id, 'red');
      expect(look(slotPhoto(token: blue.color), onTile: true).company?.id, 'blue');
    });

    test('warm light does not make an empty slot look like a token', () {
      final seen = look(slotPhoto(light: const Color(0xFFFFE0B0)), onTile: true);
      expect(seen.present, isFalse);
    });

    test('a token on a tile is seen under warm light too', () {
      final seen = look(
          slotPhoto(token: red.color, light: const Color(0xFFFFE0B0)),
          onTile: true);
      expect(seen.present, isTrue);
      expect(seen.company?.id, 'red');
    });

    test('companies printed in the same colour are told apart by home', () {
      // BLS and GB tokens are the same mustard. On Bern, BLS's home, it is
      // BLS's; anywhere else it could be either, and the app says so.
      final photo = slotPhoto(token: bls.color);
      final atHome =
          look(photo, onTile: true, home: bls, companies: title1844.companies);
      expect(atHome.company?.id, 'BLS');
      expect(atHome.companyConfidence, greaterThan(0.5));
      final away = look(photo, onTile: true, companies: title1844.companies);
      expect(away.present, isTrue);
      expect(['BLS', 'GB'], contains(away.company?.id));
      expect(away.companyConfidence, lessThan(0.5));
    });

    test("a printed home city's logo is not taken for a token", () {
      // The map prints each company's logo in its home city, on white.
      final seen = look(slotPhoto(logo: true),
          onTile: false, home: gb, companies: title1844.companies);
      expect(seen.present, isFalse);
    });

    test("the home company's token is seen on its printed home city", () {
      final seen = look(slotPhoto(token: gb.color),
          onTile: false, home: gb, companies: title1844.companies);
      expect(seen.present, isTrue);
      expect(seen.company?.id, 'GB');
    });

    test('a printed city with its own art is left alone', () {
      // Lucerne's slot holds a lake: coloured, and not anyone's home.
      final seen = look(slotPhoto(printed: const Color(0xFF7FA6E0), logo: true),
          onTile: false, companies: title1844.companies);
      expect(seen.present, isFalse);
      expect(seen.confidence, 0, reason: "can't tell, so nothing changes");
    });

    test('a slot outside the photo is not seen at all', () {
      final photo = slotPhoto(token: red.color);
      final seen = TokenDetector().detect(
        photo: photo,
        boardToImage: boardToImage,
        slot: const Offset(9, 9),
        slotRadius: slotRadius,
        white: TokenDetector.localWhite(photo, boardToImage, slot),
        onTile: true,
      );
      expect(seen.present, isFalse);
      expect(seen.confidence, 0);
    });

    test('colours are read as tobymao writes them', () {
      expect(Company.parseColor('#c1b22b'), const Color(0xFFC1B22B));
      expect(Company.parseColor('#fff'), const Color(0xFFFFFFFF));
      expect(Company.parseColor('black'), const Color(0xFF000000));
    });
  });

  group('revenue text', () {
    test('reads a plain number', () {
      final reading = RevenueOcr.parseRecognizedText('30');
      expect(reading.value, 30);
      expect(reading.recognized, isTrue);
    });

    test('picks the revenue when the crop caught other text', () {
      // City circles often sit next to a slot marker or tile number.
      expect(RevenueOcr.parseRecognizedText('2\n40').value, 40);
      expect(RevenueOcr.parseRecognizedText('B 60 OO').value, 60);
    });

    test('reports nothing readable rather than guessing', () {
      final reading = RevenueOcr.parseRecognizedText('   ');
      expect(reading.recognized, isFalse);
      expect(reading.value, isNull);
    });

    test('ignores numbers too large to be revenue', () {
      expect(RevenueOcr.parseRecognizedText('1830').recognized, isFalse);
      expect(RevenueOcr.parseRecognizedText('1830 40').value, 40);
    });
  });
}
