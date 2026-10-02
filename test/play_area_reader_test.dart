import 'dart:io';
import 'dart:ui' show Rect;

import 'package:eighteen_xx_calculator/models/game_title.dart';
import 'package:eighteen_xx_calculator/processing/play_area_reader.dart';
import 'package:eighteen_xx_calculator/processing/revenue_ocr.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// A line read at [box] -- left, top, right, bottom, 0 to 1 -- as Vision
/// reports lines.
RecognizedWord line(List<double> box, String text) =>
    RecognizedWord(text, box[0], box[2], top: box[1], bottom: box[3]);

/// What Vision read in a photo of GB's charter beside two of its
/// certificates (a 50% director's share on top of a 25% share), with its
/// 3H and 2H trains and one token left on the charter
/// (board_1790912047858.png, 1920 x 1080).
final gbPhoto = [
  line([0.032, 0.499, 0.052, 0.514], '5% DI'),
  line([0.060, 0.499, 0.160, 0.527], '503 DIVIDENDE / DIVIDEND'),
  line([0.097, 0.576, 0.122, 0.605], 'GB'),
  line([0.211, 0.506, 0.247, 0.522], 'Director v'),
  line([0.144, 0.537, 0.221, 0.556], '2 ANTEILE/ SHARES'),
  line([0.138, 0.558, 0.222, 0.659], '50%'),
  line([0.164, 0.685, 0.230, 0.700], 'Gotthardbaha (V5)'),
  line([0.235, 0.690, 0.247, 0.713], '+'),
  line([0.330, 0.031, 0.365, 0.072], 'GB'),
  line([0.398, 0.046, 0.569, 0.085], 'Gotthardbahn (V5)'),
  line([0.295, 0.234, 0.355, 0.262], 'Limit 2'),
  line([0.469, 0.243, 0.525, 0.261], 'Loks/tr'),
  line([0.599, 0.235, 0.680, 0.258], 'ane Lokpilichr'),
  line([0.602, 0.261, 0.714, 0.284], 'ne Notlnanzierung'),
  line([0.586, 0.282, 0.724, 0.308], 'k-ine Privatbahn kaufen'),
  line([0.584, 0.310, 0.702, 0.333], 'fusioniert in die SBB'),
  line([0.326, 0.339, 0.372, 0.401], '3н'),
  line([0.388, 0.349, 0.435, 0.406], '2H'),
  line([0.536, 0.349, 0.562, 0.372], '70гг'),
  line([0.401, 0.509, 0.548, 0.527], '„Limmat" Zürich - Baden 1847'),
  line([0.302, 0.625, 0.315, 0.638], 'Typ'),
  line([0.301, 0.638, 0.317, 0.651], 'Туре'),
  line([0.298, 0.669, 0.320, 0.685], '2/2H'),
  line([0.298, 0.690, 0.320, 0.703], '3/3H'),
  line([0.298, 0.708, 0.320, 0.721], '4/4H'),
  line([0.298, 0.726, 0.320, 0.742], '5/5H'),
  line([0.344, 0.607, 0.378, 0.623], 'Lak / Train'),
  line([0.350, 0.625, 0.368, 0.636], 'Preis'),
  line([0.352, 0.641, 0.366, 0.646], 'nice'),
  line([0.350, 0.674, 0.366, 0.680], '90/0'),
  line([0.346, 0.690, 0.372, 0.700], '180/150'),
  line([0.347, 0.708, 0.372, 0.721], '300/260'),
  line([0.347, 0.726, 0.372, 0.739], '450/400'),
  line([0.379, 0.630, 0.395, 0.641], 'Limit'),
  line([0.458, 0.630, 0.468, 0.641], 'OR'),
  line([0.484, 0.610, 0.528, 0.623], 'Gleistelle /Trs'),
  line([0.484, 0.625, 0.513, 0.638], 'Verfüghar'),
  line([0.485, 0.641, 0.510, 0.646], 'Abasiaale'),
  line([0.432, 0.690, 0.453, 0.703], '2) 2H'),
  line([0.408, 0.708, 0.419, 0.721], '2H'),
  line([0.798, 0.127, 0.826, 0.150], '0 Fr.'),
  line([0.852, 0.129, 0.885, 0.153], '40 Fr.'),
  line([0.737, 0.240, 0.879, 0.264], 'no obligation to own train'),
  line([0.735, 0.269, 0.869, 0.292], 'no emergency financing'),
  line([0.735, 0.292, 0.904, 0.318], 'cannot buy Private Companies'),
  line([0.734, 0.318, 0.821, 0.341], 'merge into SBB'),
];

/// What Vision read in a photo of FNM's charter -- a 6 and a 4 on it, two
/// tokens left in its 100 Fr. places, the others showing the figures
/// printed in them -- beside a stack of its certificates: a 20% director's
/// share on top of three 10% shares (board_1790917100047.png).
final fnmPhoto = [
  line([0.101, 0.406, 0.181, 0.442], '3 DIVIDENDE • DIVIDEAD'),
  line([0.222, 0.398, 0.246, 0.411], 'Director'),
  line([0.165, 0.424, 0.232, 0.454], '2 ANTEILE/SHARES'),
  line([0.121, 0.473, 0.156, 0.506], 'FNM'),
  line([0.163, 0.447, 0.234, 0.537], '20%'),
  line([0.163, 0.543, 0.244, 0.574], 'Ferrovie Hord Milano (H1)'),
  line([0.314, 0.147, 0.368, 0.194], 'FNM'),
  line([0.384, 0.164, 0.449, 0.195], 'Ferrovie'),
  line([0.382, 0.198, 0.518, 0.233], 'Nord Milano (HI)'),
  line([0.290, 0.314, 0.372, 0.341], 'Limit 4/3/2'),
  line([0.311, 0.385, 0.333, 0.434], '6'),
  line([0.307, 0.470, 0.350, 0.496], 'NELnE'),
  line([0.318, 0.522, 0.355, 0.537], '„Krokor'),
  line([0.440, 0.326, 0.510, 0.346], 'Loks/Trains'),
  line([0.494, 0.395, 0.526, 0.419], '300гr'),
  line([0.406, 0.535, 0.490, 0.553], 'Eb 3/5, Baujahr 1904'),
  line([0.286, 0.618, 0.298, 0.628], 'Typ'),
  line([0.283, 0.628, 0.298, 0.638], 'Тури'),
  line([0.281, 0.656, 0.299, 0.669], '2/2H'),
  line([0.279, 0.674, 0.299, 0.687], '3/3Н'),
  line([0.279, 0.693, 0.298, 0.705], '4/4H'),
  line([0.278, 0.726, 0.297, 0.739], '5/5H'),
  line([0.326, 0.661, 0.347, 0.674], '90/70'),
  line([0.321, 0.677, 0.350, 0.690], '180/150'),
  line([0.321, 0.695, 0.350, 0.708], '300/260'),
  line([0.320, 0.729, 0.347, 0.742], '450/400'),
  line([0.318, 0.760, 0.349, 0.775], '630/550'),
  line([0.317, 0.778, 0.350, 0.793], '960/700'),
  line([0.375, 0.780, 0.385, 0.793], '1H'),
  line([0.581, 0.181, 0.602, 0.204], '60'),
  line([0.631, 0.235, 0.660, 0.253], '40 г-'),
  line([0.685, 0.243, 0.722, 0.264], '100 Fг'),
  line([0.746, 0.245, 0.782, 0.264], '100 гr'),
  line([0.801, 0.251, 0.840, 0.274], '100 Fr.'),
  line([0.545, 0.318, 0.650, 0.333], 'Anzathl der Balhnior'),
  line([0.542, 0.339, 0.660, 0.357], 'muniber of statine mioet'),
  line([0.737, 0.328, 0.818, 0.346], 'vom Ausgabeku'),
  line([0.730, 0.346, 0.762, 0.362], 'n PAR'),
  line([0.863, 0.742, 0.876, 0.757], 'Ion'),
];

/// A photo the size of the GB one, plain card where the token places are,
/// with a dark token drawn over the place above "40 Fr." and an empty ring
/// above "0 Fr.".
img.Image charterWithOneToken() {
  final photo = img.Image(width: 1920, height: 1080);
  img.fill(photo, color: img.ColorRgb8(70, 50, 40));
  img.fillRect(photo,
      x1: 1400, y1: 0, x2: 1900, y2: 300, color: img.ColorRgb8(225, 210, 180));
  void place(List<double> label, {required bool token}) {
    final h = (label[3] - label[1]) * 1080;
    final cx = ((label[0] + label[2]) / 2 * 1920).round();
    final cy = (label[1] * 1080 - 2.6 * h).round();
    final r = (1.7 * h).round();
    if (token) {
      img.fillCircle(photo, x: cx, y: cy, radius: r,
          color: img.ColorRgb8(60, 60, 70));
    } else {
      img.drawCircle(photo, x: cx, y: cy, radius: r,
          color: img.ColorRgb8(110, 100, 90));
    }
    // The cost itself, as a dark blot.
    img.fillRect(photo,
        x1: (label[0] * 1920).round() + 4,
        y1: (label[1] * 1080).round() + 3,
        x2: (label[2] * 1920).round() - 4,
        y2: (label[3] * 1080).round() - 3,
        color: img.ColorRgb8(90, 80, 70));
  }

  place([0.798, 0.127, 0.826, 0.150], token: false);
  place([0.852, 0.129, 0.885, 0.153], token: true);
  return photo;
}

void main() {
  final title = GameTitle.byId('1844')!;

  group("GB's charter and certificates", () {
    final reading = PlayAreaReader(title).read(gbPhoto, aspect: 1920 / 1080);

    test('finds the charter and its trains, leaving the table of trains',
        () {
      expect(reading.charters, hasLength(1));
      final charter = reading.charters.single;
      expect(charter.company.id, 'GB');
      expect(charter.trains, ['3H', '2H']);
    });

    test("finds its token places by GB's token costs, not the train's price",
        () {
      final charter = reading.charters.single;
      expect(charter.slots.map((s) => s.cost), [0, 40]);
      // Without the photo, nothing is said about what's in them.
      expect(charter.tokens, isNull);
    });

    test('reads each certificate in the stack once', () {
      expect(reading.certificates, hasLength(1));
      final held = reading.certificates.single;
      expect(held.company.id, 'GB');
      expect(held.percents, [50, 25]);
      expect(held.total, 75);
    });

    test('sees the token left on the charter', () {
      final withPhoto = PlayAreaReader(title)
          .read(gbPhoto, photo: charterWithOneToken())
          .charters
          .single;
      expect([for (final s in withPhoto.slots) s.filled], [false, true]);
      expect(withPhoto.tokens, 1);
    });

    test('says nothing of tokens when the home place looks covered', () {
      final photo = charterWithOneToken();
      // A token drawn over the home place too: the charter isn't laid out
      // the way the reader expects.
      img.fillCircle(photo,
          x: (0.812 * 1920).round(),
          y: (0.127 * 1080 - 2.6 * 0.023 * 1080).round(),
          radius: 42,
          color: img.ColorRgb8(60, 60, 70));
      final charter =
          PlayAreaReader(title).read(gbPhoto, photo: photo).charters.single;
      expect(charter.tokens, isNull);
    });

    test('the real photo, when it is there', () {
      final photo = img.decodePng(File(Platform.environment['PLAY_PHOTO']!)
          .readAsBytesSync())!;
      final charter =
          PlayAreaReader(title).read(gbPhoto, photo: photo).charters.single;
      expect([for (final s in charter.slots) s.filled], [false, true]);
      final face = gbPhoto.firstWhere((l) => l.text == '50%');
      expect(
          PlayAreaReader.stackUnder(photo,
              Rect.fromLTRB(face.left, face.top, face.right, face.bottom)),
          [2, 1]);
    },
        skip: Platform.environment['PLAY_PHOTO'] == null
            ? 'Set PLAY_PHOTO to board_1790912047858.png'
            : false);
  });

  group("FNM's charter and certificates", () {
    final photoPath = Platform.environment['FNM_PHOTO'];

    test('a train whose number was missed is known by its price', () {
      final charter = PlayAreaReader(title)
          .read(fnmPhoto, aspect: 1920 / 1080)
          .charters
          .single;
      expect(charter.company.id, 'FNM');
      // The 4 card's number wasn't read; its 300 Fr. is the 4's price.
      expect(charter.trains, ['6', '4']);
      // Four of the five places' costs were read (not the home one's).
      expect(charter.slots.map((s) => s.cost), [40, 100, 100, 100]);
    });

    test('without the photo, only the top certificate is read', () {
      // Its edge reads "3 DIVIDENDE": nothing FNM prints.
      expect(
          PlayAreaReader(title)
              .read(fnmPhoto, aspect: 1920 / 1080)
              .certificates
              .single
              .percents,
          [20]);
    });

    test('the real photo: silver tokens, and the stack counted by its '
        'stripes', () {
      final photo = img.decodePng(File(photoPath!).readAsBytesSync())!;
      final reading = PlayAreaReader(title).read(fnmPhoto, photo: photo);
      final charter = reading.charters.single;
      expect([for (final s in charter.slots) s.filled],
          [false, false, true, true]);
      expect(charter.tokens, 2);
      expect(reading.certificates.single.percents, [20, 10, 10, 10]);
    },
        skip: photoPath == null
            ? 'Set FNM_PHOTO to board_1790917100047.png'
            : false);
  });

  group('reading text', () {
    test('a line naming no company finds nothing', () {
      expect(
          PlayAreaReader(title)
              .read([line([0.1, 0.1, 0.2, 0.2], '3H')], aspect: 1)
              .isEmpty,
          isTrue);
    });

    test('certificates alone, without a charter', () {
      final reading = PlayAreaReader(title).read([
        line([0.10, 0.10, 0.20, 0.12], 'GB'),
        line([0.05, 0.05, 0.15, 0.07], '25% DIVIDENDE'),
        line([0.12, 0.05, 0.22, 0.07], '25% DIVIDENDE'),
      ], aspect: 1);
      expect(reading.charters, isEmpty);
      expect(reading.certificates.single.percents, [25, 25]);
    });

    test('names misread a letter or two still find their company', () {
      final reading = PlayAreaReader(title).read([
        line([0.1, 0.0, 0.4, 0.05], 'Gotthardbaнn (V5)'),
        line([0.1, 0.3, 0.15, 0.4], '4н'),
        line([0.5, 0.5, 0.52, 0.51], 'small print'),
        line([0.5, 0.6, 0.52, 0.61], 'more small print'),
      ], aspect: 1);
      expect(reading.charters.single.company.id, 'GB');
      expect(reading.charters.single.trains, ['4H']);
    });
  });
}
