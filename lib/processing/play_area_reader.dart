import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:image/image.dart' as img;

import '../models/company.dart';
import '../models/game_title.dart';
import 'revenue_ocr.dart';

/// A place for a station token on a company's charter.
class TokenSlot {
  /// What laying the token there costs, as printed under it.
  final int cost;

  /// Where the printed cost was read: 0 to 1 across and down the photo.
  final Rect label;

  /// Whether a token sits there; null when the photo doesn't say.
  final bool? filled;

  const TokenSlot(this.cost, this.label, {this.filled});
}

/// What a photo shows of one company's charter.
class CharterReading {
  final Company company;

  /// The trains on it, by the title's names for them, left to right.
  final List<String> trains;

  /// Its places for station tokens, as read.
  final List<TokenSlot> slots;

  const CharterReading(this.company,
      {this.trains = const [], this.slots = const []});

  /// How many tokens are still on it: null when the photo doesn't say.
  int? get tokens => slots.isEmpty || slots.any((s) => s.filled == null)
      ? null
      : slots.where((s) => s.filled!).length;
}

/// The share certificates a photo shows of one company: each one's
/// percentage.
class CertificateReading {
  final Company company;
  final List<int> percents;

  const CertificateReading(this.company, this.percents);

  int get total => percents.fold(0, (t, p) => t + p);
}

/// What a photo of a player's area shows: company charters, with their
/// trains and the tokens left on them, and share certificates.
class PlayAreaReading {
  final List<CharterReading> charters;
  final List<CertificateReading> certificates;

  /// How many of [charters] have their company's name above what was read
  /// on them, as a charter is printed: how sure it is that the photo was
  /// read the right way up (text recognition reads upside down too).
  final int upright;

  const PlayAreaReading({
    this.charters = const [],
    this.certificates = const [],
    this.upright = 0,
  });

  bool get isEmpty => charters.isEmpty && certificates.isEmpty;
}

/// Makes sense of the text read from a photo of a player's area.
///
/// Companies are found by name or symbol (the logo's letters), and each
/// thing found goes with the nearest of them: train cards -- a train's name
/// in large print -- and token places -- a cost printed with its currency,
/// one of the company's token costs -- with a charter; percentages with
/// certificates. Certificates are stacked to show each one's top edge,
/// where its percentage is printed, so every edge read is a certificate,
/// and the large figure on the top one is the same one again.
class PlayAreaReader {
  final GameTitle title;

  const PlayAreaReader(this.title);

  /// Reads the [lines] recognized in [photo]. Without the photo, token
  /// places are found but not whether they're filled, and [aspect] -- how
  /// many times wider than tall the photo is -- says how far apart things
  /// are.
  PlayAreaReading read(
    List<RecognizedWord> recognized, {
    img.Image? photo,
    double? aspect,
  }) {
    final across = aspect ?? (photo == null ? 1.0 : photo.width / photo.height);
    Offset centre(RecognizedWord w) =>
        Offset((w.left + w.right) / 2 * across, (w.top + w.bottom) / 2);
    final trainNames = {for (final t in title.trains) _key(t.name): t.name};
    final lines = [
      for (final line in recognized)
        for (final piece in _costsIn(line)) ..._trainsIn(piece, trainNames),
    ];

    // A charter may print its company's name over two lines ("Ferrovie" /
    // "Nord Milano (H1)"), so each line is tried with the one under it too;
    // and a recognizer may run a logo's letters into the name beside them
    // ("FNM Ferrovie"), so a symbol leading a line counts.
    final anchors = <(Company, Offset)>[];
    for (final line in lines) {
      if (_companyNamed(line.text) ?? _symbolLeading(line.text)
          case final company?) {
        anchors.add((company, centre(line)));
        continue;
      }
      final below = _under(line, lines);
      if (below == null) continue;
      if (_companyNamed('${line.text} ${below.text}') case final company?) {
        anchors.add((company, (centre(line) + centre(below)) / 2));
      }
    }
    if (anchors.isEmpty) return const PlayAreaReading();

    // Train cards: a train's name, printed larger than most of what's
    // around it -- the charter's table of trains names them too, small.
    String? trainIn(RecognizedWord line) {
      if (line.text.contains('/')) return null;
      final key = _key(line.text);
      return trainNames[key] ??
          (title.trains.isEmpty && RegExp(r'^\d{1,2}[A-Z+]?$').hasMatch(key)
              ? key
              : null);
    }

    final others = [
      for (final l in lines)
        if (trainIn(l) == null) l.height,
    ]..sort();
    final usual = others.isEmpty ? 0.0 : others[others.length ~/ 2];
    final trains = [
      for (final l in lines)
        if (trainIn(l) case final name? when l.height >= usual * 1.5)
          (name, l),
    ]..sort((a, b) => a.$2.left.compareTo(b.$2.left));
    // The cards lie as far from the camera as each other, so their figures
    // come out alike: one much smaller is something else -- the 3 on a
    // keyboard key beside a charter.
    final tallest =
        trains.fold(0.0, (most, t) => math.max(most, t.$2.height));
    trains.removeWhere((t) => t.$2.height < tallest / 2);
    trains.sort((a, b) => a.$2.left.compareTo(b.$2.left));

    // Token places: a cost with its currency, `40 Fr.`, or a home place
    // that costs nothing, `FREE` (1889).
    final slots = <(int, RecognizedWord)>[
      for (final l in lines)
        if (trainIn(l) == null)
          if (_plain(l.text) == 'free')
            (0, l)
          else if (_slotPattern.firstMatch(_fold(l.text).trim()) case final m?)
            if ((m[1] != null || m[3] != null) &&
                !(m[3] ?? '').contains('%'))
              (int.parse(m[2]!), l),
    ];

    // Percentages, on a certificate's edge (`25% DIVIDENDE`) or its face.
    final percents = <(int, bool, RecognizedWord)>[
      for (final l in lines)
        if (_percentPattern.firstMatch(_fold(l.text).toUpperCase())
            case final m?)
          if (m[2] != null || _fold(l.text).toUpperCase().contains('DIVID'))
            (int.parse(m[1]!), m[2] != null, l),
    ];

    // A company's name on a charter is nearest something of the charter's;
    // on a certificate, a percentage.
    final onCertificate = <int>{};
    for (int a = 0; a < anchors.length; a++) {
      final at = anchors[a].$2;
      double nearest(Iterable<RecognizedWord> items) => items.fold(
          double.infinity, (d, w) => math.min(d, (centre(w) - at).distance));
      final charterItem = nearest([
        for (final t in trains) t.$2,
        for (final s in slots) s.$2,
      ]);
      if (nearest([for (final p in percents) p.$3]) < charterItem) {
        onCertificate.add(a);
      }
    }
    Company? nearestCompany(RecognizedWord item, {required bool certificate}) {
      Company? best;
      var distance = double.infinity;
      for (final pass in [true, false]) {
        for (int a = 0; a < anchors.length; a++) {
          if (pass && onCertificate.contains(a) != certificate) continue;
          final d = (anchors[a].$2 - centre(item)).distance;
          if (d < distance) {
            distance = d;
            best = anchors[a].$1;
          }
        }
        if (best != null) break;
      }
      return best;
    }

    // A card whose large figure wasn't read can say which train it is in
    // its small print -- 1889's cards say what scraps them: `RUSTED BY 4`
    // is a 2 -- and of cards fanned out, only the top one's is whole, the
    // rest showing `RUS`. So a company has as many of a train as its cards'
    // figures or their small print say, whichever is more; a part line
    // counts where the company's whole ones name only the one train.
    final said = <Company, List<(String?, RecognizedWord)>>{};
    for (final l in lines) {
      final text = _fold(l.text).toUpperCase().trim();
      final String? name;
      if (_rustedBy.firstMatch(text) case final m?) {
        final by = m[1]!.toUpperCase();
        final scrapped = [
          for (final t in title.trains)
            if (t.rustsOn?.toUpperCase() == by && t.base == t.name) t.name,
        ];
        if (scrapped.length != 1) continue;
        name = scrapped.single;
      } else if (text.startsWith('RUS')) {
        name = null;
      } else {
        continue;
      }
      said
          .putIfAbsent(nearestCompany(l, certificate: false)!, () => [])
          .add((name, l));
    }
    said.forEach((company, notes) {
      final named = {for (final (name, _) in notes) ?name};
      final cards = <String, List<RecognizedWord>>{};
      for (final (name, line) in notes) {
        final train = name ?? (named.length == 1 ? named.single : null);
        if (train != null) cards.putIfAbsent(train, () => []).add(line);
      }
      cards.forEach((train, smallPrint) {
        final figures = trains
            .where((t) =>
                t.$1 == train &&
                nearestCompany(t.$2, certificate: false) == company)
            .length;
        for (final line in smallPrint.skip(figures)) {
          trains.add((train, line));
        }
      });
    });

    // A train card whose number wasn't read -- a single figure is the
    // hardest thing to read -- still shows its price, and where only one
    // kind of train costs that, the price says which. A card whose number
    // was read shows its price too, beside it, so that one isn't counted
    // twice.
    final byPrice = <int, List<String>>{};
    for (final t in title.trains) {
      if (t.price > 0) byPrice.putIfAbsent(t.price, () => []).add(t.name);
    }
    for (final (cost, line) in slots) {
      final named = byPrice[cost];
      if (named == null || named.length != 1) continue;
      final name = named.single;
      final company = nearestCompany(line, certificate: false)!;
      if (company.tokenCosts.contains(cost)) continue;
      final shown = trains.any((t) =>
          t.$1 == name &&
          t.$2.right <= line.left &&
          (line.left - t.$2.right) * across < 5 * t.$2.height &&
          ((t.$2.top + t.$2.bottom) / 2 - (line.top + line.bottom) / 2).abs() <
              t.$2.height);
      if (!shown) trains.add((name, line));
    }
    trains.sort((a, b) => a.$2.left.compareTo(b.$2.left));

    // Charters.
    final charterTrains = <Company, List<String>>{};
    for (final (name, line) in trains) {
      final company = nearestCompany(line, certificate: false)!;
      charterTrains.putIfAbsent(company, () => []).add(name);
    }
    final charterSlots = <Company, List<RecognizedWord>>{};
    final slotCosts = <RecognizedWord, int>{};
    for (final (cost, line) in slots) {
      final company = nearestCompany(line, certificate: false)!;
      if (!company.tokenCosts.contains(cost)) continue;
      charterSlots.putIfAbsent(company, () => []).add(line);
      slotCosts[line] = cost;
    }
    // A charter that prints its free place as `FREE` (1889) has no `0`
    // place besides: that is something else, a keyboard's 0 key, say.
    for (final found in charterSlots.values) {
      if (found.any((l) => _plain(l.text) == 'free')) {
        found.removeWhere(
            (l) => slotCosts[l] == 0 && _plain(l.text) != 'free');
      }
    }
    // A place with a token on it can have its cost covered -- 1889 prints
    // the cost beside the ring -- and isn't read. Tokens leave the charter
    // from the left, so the places read are the first of the company's
    // costs, evenly spaced in a row, and the rest are further along it. (A
    // place whose cost isn't printed at all, like an 1844 home place, isn't
    // one of the first, and nothing is made up.) Where only 1889's `FREE`
    // is read -- the company's one other place has its token on it -- the
    // next place is two of the word's widths along: so it is on all five
    // charters photographed.
    charterSlots.forEach((company, found) {
      if (found.isEmpty || found.length >= company.tokenCosts.length) return;
      final row = [...found]..sort((a, b) => a.left.compareTo(b.left));
      for (int i = 0; i < row.length; i++) {
        if (slotCosts[row[i]] != company.tokenCosts[i]) return;
      }
      final missing = company.tokenCosts.sublist(row.length);
      final Offset step;
      if (row.length >= 2) {
        step = Offset(row[1].left - row[0].left, row[1].top - row[0].top);
      } else if (_plain(row.single.text) == 'free') {
        step = Offset(2 * row.single.width, 0);
      } else {
        return;
      }
      if (step.dx <= 0) return;
      for (int i = 2; i < row.length; i++) {
        final gap = Offset(row[i].left - row[i - 1].left, row[i].top - row[i - 1].top);
        if ((gap - step).distance > 0.25 * step.distance) return;
      }
      var last = row.last;
      for (final cost in missing) {
        final next = RecognizedWord('', last.left + step.dx, last.right + step.dx,
            top: last.top + step.dy, bottom: last.bottom + step.dy);
        if (next.right > 1 || next.bottom > 1) break;
        found.add(next);
        slotCosts[next] = cost;
        last = next;
      }
    });
    final charters = <CharterReading>[
      for (final company in {...charterTrains.keys, ...charterSlots.keys})
        CharterReading(
          company,
          trains: charterTrains[company] ?? const [],
          slots: _slotsOf(
            [
              for (final line in charterSlots[company] ?? const <RecognizedWord>[])
                (slotCosts[line]!, line),
            ],
            photo,
          ),
        ),
    ];

    // Certificates: every edge read is one; the large figure on the top
    // card of a stack is its edge again, unless the edge wasn't read.
    final byCompany = <Company, List<(int, bool, RecognizedWord)>>{};
    for (final p in percents) {
      final company = nearestCompany(p.$3, certificate: true)!;
      final sizes = company.shares.toSet();
      final value = _resolve(p.$1, p.$2, sizes);
      if (value == null) continue;
      byCompany.putIfAbsent(company, () => []).add((value, p.$2, p.$3));
    }
    final certificates = <CertificateReading>[];
    // 1889's certificates are fanned so that a strip along each card shows
    // its share -- `1 SHARE  10%` -- and every percentage beside a SHARE is
    // a card of its own; there is no large figure repeating the top one.
    final shares = [
      for (final l in lines)
        if (RegExp(r'^\d?\s*SHARES?$').hasMatch(_key(l.text))) l,
    ];
    bool onStrip(RecognizedWord p) => shares.any((s) =>
        (centre(s) - centre(p)).distance <
        8 * math.max(p.height, s.height));
    byCompany.forEach((company, found) {
      if (found.every((f) => onStrip(f.$3))) {
        certificates.add(CertificateReading(
            company, [for (final f in found) f.$1]..sort((a, b) => b - a)));
        return;
      }
      final big = [
        for (final f in found)
          if (f.$2 && f.$3.height >= usual * 2.5) f,
      ];
      // Stripes, where the photo shows them, count the cards under each
      // large figure better than their edges' small print can be read.
      if (photo != null && big.isNotEmpty) {
        final striped = <int>[];
        for (final face in big) {
          final w = face.$3;
          final stack = stackUnder(
              photo, Rect.fromLTRB(w.left, w.top, w.right, w.bottom));
          if (stack.isEmpty) continue;
          striped.add(face.$1);
          for (final stripes in stack.skip(1)) {
            striped.add(_shareOf(company, stripes));
          }
        }
        if (striped.isNotEmpty) {
          certificates.add(
              CertificateReading(company, striped..sort((a, b) => b - a)));
          return;
        }
      }
      final edges = [
        for (final f in found)
          if (!big.contains(f)) f,
      ];
      final percents = [for (final e in edges) e.$1];
      for (final face in big) {
        final w = face.$3;
        final shown = edges.any((e) =>
            e.$1 == face.$1 &&
            e.$3.left < w.left &&
            (w.left - e.$3.left) * across < 4 * w.height &&
            ((e.$3.top + e.$3.bottom) / 2 - w.top).abs() < 2 * w.height);
        if (!shown) percents.add(face.$1);
      }
      if (percents.isNotEmpty) {
        certificates.add(
            CertificateReading(company, percents..sort((a, b) => b - a)));
      }
    });

    // The right way up, a charter's name is above its trains and places.
    var upright = 0;
    for (final charter in charters) {
      // The name on the charter itself, not on a certificate beside it.
      final names = [
        for (int a = 0; a < anchors.length; a++)
          if (anchors[a].$1 == charter.company && !onCertificate.contains(a))
            anchors[a].$2,
      ];
      if (names.isEmpty) continue;
      final top = names.map((a) => a.dy).reduce(math.min);
      final items = [
        for (final (_, line) in trains)
          if (nearestCompany(line, certificate: false) == charter.company)
            centre(line).dy,
        for (final slot in charter.slots) slot.label.center.dy,
      ];
      if (items.isNotEmpty && items.where((y) => y > top).length * 2 > items.length) {
        upright++;
      }
    }
    return PlayAreaReading(
        charters: charters, certificates: certificates, upright: upright);
  }

  /// The token places read, cheapest first, and whether a token covers
  /// each. A token looks nothing like its empty place, but tokens do differ
  /// from game to game -- 1844's GB is dark, FNM's silver -- and so do empty
  /// places, plain or with a figure printed in them; so the places on a
  /// charter are told apart by how far each one's inside is from the card
  /// around it, against the others: where they split clearly into two
  /// kinds, the further kind holds tokens. Where they are all alike, they
  /// are all empty if they look like the card, all full if they don't, and
  /// otherwise nothing is said.
  ///
  /// The home token always leaves its place when the company starts, so if
  /// the place costing nothing looks full the charter isn't laid out as
  /// expected, and nothing is said either.
  static List<TokenSlot> _slotsOf(
      List<(int, RecognizedWord)> found, img.Image? photo) {
    found.sort((a, b) => a.$1.compareTo(b.$1));
    Rect rect(RecognizedWord w) =>
        Rect.fromLTRB(w.left, w.top, w.right, w.bottom);
    if (photo == null) {
      return [for (final (cost, w) in found) TokenSlot(cost, rect(w))];
    }
    final differences = [
      for (final (_, w) in found) interiorDifference(photo, rect(w)),
    ];
    final known = differences.nonNulls.toList()..sort();
    bool? filledAt(double? d) {
      if (d == null || known.isEmpty) return null;
      if (known.last - known.first >= _placesSplit) {
        return d > (known.first + known.last) / 2;
      }
      return d < _placeEmpty
          ? false
          : d > _placeFull
              ? true
              : null;
    }

    final filled = [for (final d in differences) filledAt(d)];
    final home = found.indexWhere((f) => f.$1 == 0);
    final trusted = home < 0 || filled[home] == false;
    return [
      for (int i = 0; i < found.length; i++)
        TokenSlot(found[i].$1, rect(found[i].$2),
            filled: trusted ? filled[i] : null),
    ];
  }

  /// How far apart in colour (RGB distance from the card) a charter's
  /// places have to spread to be split into empty and full; and, all alike,
  /// what counts as plainly empty and plainly full.
  static const double _placesSplit = 20;
  static const double _placeEmpty = 15;
  static const double _placeFull = 40;

  /// The cards stacked under the one whose large figure is at [face], top
  /// card first, as how many stripes each shows on its edge: one for a
  /// single share, two for a double. Empty when no stripes are found.
  ///
  /// Certificates are fanned out so that each one's edge shows, and the
  /// edge carries a stripe or two -- in some colour that isn't the card's
  /// white -- from top to bottom. So a band across the stack at the
  /// figure's height crosses each card's stripes in turn: narrow runs of
  /// columns that aren't card all the way down the band. The company's
  /// logo, between the top card's stripes and its figure, has white in it
  /// at some heights and not others, so its columns don't count; the stack
  /// ends at the first wide stretch that is solidly something else, the
  /// table. Stripes a stripe's width apart are one card's.
  @visibleForTesting
  static List<int> stackUnder(img.Image photo, Rect face,
      {void Function(String)? log}) {
    final fh = face.height * photo.height;
    if (fh < 8) return const [];
    final cy = face.center.dy * photo.height;
    final step = math.max(1.0, fh / 24);
    final rows = [
      for (var y = cy - _stackBand * fh; y <= cy + _stackBand * fh; y += step)
        y.round(),
    ];
    // The card's white: the lightest of what is around the figure.
    final around = <double>[];
    final fx0 = (face.left * photo.width).round();
    final fx1 = (face.right * photo.width).round();
    for (final y in rows) {
      for (int x = fx0; x <= fx1; x += 2) {
        if (x < 0 || y < 0 || x >= photo.width || y >= photo.height) continue;
        final p = photo.getPixel(x, y);
        around.add(0.299 * p.r + 0.587 * p.g + 0.114 * p.b);
      }
    }
    if (around.length < 10) return const [];
    around.sort();
    final white = around[(around.length * 0.9).floor()];
    bool card(img.Pixel p) {
      final l = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      final hi = math.max(p.r, math.max(p.g, p.b));
      final lo = math.min(p.r, math.min(p.g, p.b));
      return l > white * 0.75 && hi > 0 && (hi - lo) / hi < 0.18;
    }

    // Each column of the band: 1 card, 2 not card all the way down, 0
    // something of both.
    final from = fx0 - (0.05 * fh).round();
    final to = math.max(0, fx0 - (_stackReach * fh).round());
    final runs = <(int, int, int)>[]; // kind, first x, width
    for (int x = from; x >= to; x--) {
      var cards = 0, counted = 0;
      for (final y in rows) {
        if (y < 0 || y >= photo.height || x >= photo.width) continue;
        counted++;
        if (card(photo.getPixel(x, y))) cards++;
      }
      if (counted == 0) break;
      final kind = cards >= counted * 0.6
          ? 1
          : counted - cards >= counted * 0.85
              ? 2
              : 0;
      if (runs.isNotEmpty && runs.last.$1 == kind) {
        runs.last = (kind, runs.last.$2, runs.last.$3 + 1);
      } else {
        runs.add((kind, x, 1));
      }
    }
    log?.call('runs ${[for (final r in runs) if (r.$3 >= 2) '${['-', 'card', 'STRIPE'][r.$1]} ${r.$2} w${r.$3}']}');

    final stripes = <int>[]; // where each starts, right to left
    for (final (kind, x, width) in runs) {
      if (kind != 2) continue;
      if (width >= 0.03 * fh && width <= 0.2 * fh) {
        stripes.add(x);
      } else if (width > 0.5 * fh && stripes.isNotEmpty) {
        break; // past the bottom card
      }
    }
    final cards = <int>[];
    int? last;
    for (final x in stripes) {
      if (last != null && last - x < 0.22 * fh) {
        cards[cards.length - 1]++;
      } else {
        cards.add(1);
      }
      last = x;
    }
    return cards;
  }

  /// How far above and below a certificate's large figure its stripes are
  /// looked for, and how far to the side, in the figure's heights.
  static const double _stackBand = 0.6;
  static const double _stackReach = 4.5;

  /// How far the inside of the place above the printed cost at [label] is
  /// from the card around it in colour (RGB distance), leaving out its
  /// darkest quarter -- the ring, and any figure printed in an empty place.
  /// Null when the cost is printed too small to go by.
  @visibleForTesting
  static double? interiorDifference(img.Image photo, Rect label) {
    final textHeight = label.height * photo.height;
    if (textHeight < 4) return null;
    final card = _cardColour(photo, label, textHeight);
    if (card == null) return null;
    final cx = label.center.dx * photo.width;
    final cy = label.top * photo.height - _ringAbove * textHeight;
    final radius = _ringInside * textHeight;
    final step = math.max(1.0, textHeight / 8);
    final inside = <(double, List<num>)>[];
    for (var y = cy - radius; y <= cy + radius; y += step) {
      for (var x = cx - radius; x <= cx + radius; x += step) {
        if ((x - cx) * (x - cx) + (y - cy) * (y - cy) > radius * radius) {
          continue;
        }
        if (x < 0 || y < 0 || x >= photo.width || y >= photo.height) continue;
        final p = photo.getPixel(x.toInt(), y.toInt());
        inside.add((0.299 * p.r + 0.587 * p.g + 0.114 * p.b, [p.r, p.g, p.b]));
      }
    }
    if (inside.length < 8) return null;
    inside.sort((a, b) => a.$1.compareTo(b.$1));
    final kept = inside.skip(inside.length ~/ 4).toList();
    final mean = [
      for (int c = 0; c < 3; c++)
        kept.fold<num>(0, (t, p) => t + p.$2[c]) / kept.length,
    ];
    return math.sqrt(math.pow(mean[0] - card[0], 2) +
        math.pow(mean[1] - card[1], 2) +
        math.pow(mean[2] - card[2], 2));
  }

  /// The card's colour around a printed cost: the lighter half of the band
  /// it is printed on, out to a label's width either side.
  static List<double>? _cardColour(
      img.Image photo, Rect label, double textHeight) {
    final band = <List<num>>[];
    final y0 = (label.top * photo.height).floor();
    final y1 = (label.bottom * photo.height).ceil();
    final x0 = ((label.left - label.width) * photo.width).floor();
    final x1 = ((label.right + label.width) * photo.width).ceil();
    final step = math.max(1, (textHeight / 8).floor());
    for (int y = y0; y <= y1; y += step) {
      for (int x = x0; x <= x1; x += step) {
        if (x < 0 || y < 0 || x >= photo.width || y >= photo.height) continue;
        final p = photo.getPixel(x, y);
        band.add([p.r, p.g, p.b]);
      }
    }
    if (band.length < 8) return null;
    band.sort((a, b) => (b[0] + b[1] + b[2]).compareTo(a[0] + a[1] + a[2]));
    final light = band.take(band.length ~/ 2).toList();
    return [
      for (int c = 0; c < 3; c++)
        light.fold<num>(0, (t, p) => t + p[c]) / light.length,
    ];
  }

  /// Where an 1844 charter puts a token's place: centred this many times
  /// the printed cost's height above it, with the ring's inside this many
  /// times its height across.
  static const double _ringAbove = 2.6;
  static const double _ringInside = 1.2;

  static final _slotPattern =
      RegExp(r'^([^\d\s]{1,2})?\s*(\d{1,3})\s*([^\d\s]{1,4})?$');
  static final _percentPattern = RegExp(r'^\D{0,3}?(\d{1,3})\s*(%)?');

  /// The line printed just under [line], starting about where it does: the
  /// second line of a name.
  static RecognizedWord? _under(RecognizedWord line, List<RecognizedWord> lines) {
    RecognizedWord? best;
    for (final other in lines) {
      if (identical(other, line)) continue;
      final gap = other.top - line.bottom;
      if (gap < -0.3 * line.height || gap > line.height) continue;
      if ((other.left - line.left).abs() > 2 * line.height) continue;
      if (best == null || other.top < best.top) best = other;
    }
    return best;
  }

  /// The company whose symbol is the first word of [text], for a line that
  /// runs a logo's letters into what follows. Only symbols of two letters
  /// or more: 1854's minors are numbered, and a line starting with a figure
  /// is a train, a cost or a price far more often.
  Company? _symbolLeading(String text) {
    final words = text.trim().split(RegExp(r'\s+'));
    if (words.length < 2) return null;
    final first = _plain(words.first);
    for (final c in title.companies) {
      final symbol = _plain(c.id);
      if (symbol.length >= 2 &&
          symbol.contains(RegExp('[a-z]')) &&
          first == symbol) {
        return c;
      }
    }
    return null;
  }

  /// [line] cut into the token costs it runs together -- `0 Fr. 40 Fr.
  /// 100 Fr.` -- each with its share of the line's width, as a recognizer
  /// that joins things printed in a row reads them; otherwise the line
  /// itself.
  static List<RecognizedWord> _costsIn(RecognizedWord line) {
    final text = _fold(line.text);
    final costs = [
      for (final m in _costPattern.allMatches(text))
        if (m[1] != null || m[2] != null) m,
    ];
    if (costs.length < 2) return [line];
    final covered = costs.fold(0, (t, m) => t + m[0]!.replaceAll(' ', '').length);
    if (covered < text.replaceAll(' ', '').length) return [line];
    final width = line.right - line.left;
    return [
      for (final m in costs)
        RecognizedWord(m[0]!.trim(),
            line.left + width * m.start / text.length,
            line.left + width * m.end / text.length,
            top: line.top, bottom: line.bottom),
    ];
  }

  /// [line] cut into the train names it runs together -- `8E 6`, two cards
  /// side by side -- each with its share of the line's width; otherwise the
  /// line itself. [names] are the title's train names by [_key].
  static List<RecognizedWord> _trainsIn(
      RecognizedWord line, Map<String, String> names) {
    final words = line.text.trim().split(RegExp(r'\s+'));
    if (words.length < 2 || !words.every((w) => names.containsKey(_key(w)))) {
      return [line];
    }
    final text = line.text.trim();
    final width = line.right - line.left;
    final pieces = <RecognizedWord>[];
    var from = 0;
    for (final word in words) {
      final start = text.indexOf(word, from);
      from = start + word.length;
      pieces.add(RecognizedWord(word,
          line.left + width * start / text.length,
          line.left + width * from / text.length,
          top: line.top, bottom: line.bottom));
    }
    return pieces;
  }

  /// The small print saying which train scraps a card's: `RUSTED BY 4`.
  static final _rustedBy = RegExp(r'RUSTED\s*BY\s*([0-9]{1,2}[A-Z]?|[A-Z])\b');

  /// A cost with its currency before or after it: `40 Fr.`, `¥40`.
  static final _costPattern =
      RegExp(r'([¥$£€]\s*)?\d{1,3}(\s*[A-Za-z]{1,3}\.?)?');

  /// The company [text] names, by symbol (all of it) or name (most of it).
  Company? _companyNamed(String text) {
    final plain = _plain(text);
    if (plain.isEmpty) return null;
    // Editions name a company differently at the end -- 1889's "Uwajima
    // Railroad" is tobymao's "Uwajima Railway", and its "Tosa Electric
    // Rail" -- so the part that tells it apart is compared too.
    final telling = _plain(_telling(text));
    Company? best;
    var bestLikeness = 0.0;
    for (final c in title.companies) {
      if (plain == _plain(c.id)) return c;
      final name = _plain(c.name);
      if (name.length < 5) continue;
      var likeness = _likeness(plain, name);
      final part = _plain(_telling(c.name));
      if (telling.length >= 4 && part.length >= 4) {
        likeness = math.max(likeness, _likeness(telling, part));
      } else if (part.length >= 3 && telling == part) {
        // A short one -- 1889's "Iyo Railroad", "Awa Railroad" -- only as
        // the whole of it: "Awa" is in Kubokawa too.
        likeness = 1;
      }
      if (likeness > bestLikeness) {
        bestLikeness = likeness;
        best = c;
      }
    }
    return bestLikeness >= 0.8 ? best : null;
  }

  /// [name] without the words for a railway at its end, or the edition's
  /// (V1)-style tag: the part that tells one company from another.
  static String _telling(String name) => name
      .replaceAll(RegExp(r'\(.*?\)'), ' ')
      .replaceAll(
          RegExp(r'\b(rail ?roads?|rail ?ways?|rail|line|company|co)\b\.?\s*$',
              caseSensitive: false),
          ' ')
      .trim();

  /// How alike [text] is to [name], from 0 to 1: the best match of the name
  /// against any stretch of the text as long as it.
  static double _likeness(String text, String name) {
    if (text.length <= name.length) {
      return 1 - _distance(text, name) / name.length;
    }
    var best = 0.0;
    for (int i = 0; i + name.length <= text.length; i++) {
      best = math.max(best,
          1 - _distance(text.substring(i, i + name.length), name) / name.length);
    }
    return best;
  }

  static int _distance(String a, String b) {
    var previous = List<int>.generate(b.length + 1, (i) => i);
    for (int i = 1; i <= a.length; i++) {
      final current = List<int>.filled(b.length + 1, 0)..[0] = i;
      for (int j = 1; j <= b.length; j++) {
        current[j] = math.min(
          math.min(current[j - 1] + 1, previous[j] + 1),
          previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1),
        );
      }
      previous = current;
    }
    return previous[b.length];
  }

  /// What a certificate of [company] showing [stripes] stripes is worth: a
  /// single share is the size most of its certificates are, a double share
  /// twice that (or failing that, its director's).
  static int _shareOf(Company company, int stripes) {
    final shares = company.shares;
    if (shares.isEmpty) return 10 * stripes;
    final counts = <int, int>{};
    for (final s in shares) {
      counts[s] = (counts[s] ?? 0) + 1;
    }
    final single =
        counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
    if (stripes <= 1) return single;
    return shares.contains(single * stripes) ? single * stripes : shares.first;
  }

  /// The share size a percentage read as [value] must be, given the
  /// company's [sizes]: as read, or with a `%` misread as a last digit
  /// (`503` for 50%), or with a first digit hidden under the card on top
  /// (`5%` for 25%) when only one size ends that way.
  static int? _resolve(int value, bool hasPercent, Set<int> sizes) {
    if (sizes.contains(value)) return value;
    final text = '$value';
    if (!hasPercent && text.length >= 2) {
      final cut = int.parse(text.substring(0, text.length - 1));
      if (sizes.contains(cut)) return cut;
    }
    final ending = [
      for (final s in sizes)
        if ('$s'.endsWith(text)) s,
    ];
    return ending.length == 1 ? ending.single : null;
  }

  /// [text] in capitals without spaces, lookalikes folded: what train names
  /// are matched on.
  static String _key(String text) =>
      _fold(text).toUpperCase().replaceAll(RegExp(r'\s'), '');

  /// [text] in small letters and digits alone, lookalikes folded: what
  /// company names are matched on.
  static String _plain(String text) =>
      _fold(text).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// [text] with letters from other alphabets that look like Latin ones
  /// replaced: text recognition reads 1844's `3H` as `3н`.
  static String _fold(String text) {
    final out = StringBuffer();
    for (final rune in text.runes) {
      final c = String.fromCharCode(rune);
      out.write(_lookalikes[c] ?? c);
    }
    return out.toString();
  }

  static const Map<String, String> _lookalikes = {
    // Cyrillic.
    'А': 'A', 'В': 'B', 'Е': 'E', 'З': '3', 'І': 'I', 'Ј': 'J', 'К': 'K',
    'М': 'M', 'Н': 'H', 'О': 'O', 'Р': 'P', 'С': 'C', 'Ѕ': 'S', 'Т': 'T',
    'У': 'Y', 'Х': 'X',
    'а': 'a', 'в': 'b', 'г': 'r', 'е': 'e', 'з': '3', 'и': 'u', 'і': 'i',
    'ј': 'j', 'к': 'k', 'м': 'm', 'н': 'H', 'о': 'o', 'п': 'n', 'р': 'p',
    'с': 'c', 'т': 't', 'у': 'y', 'х': 'x', 'ь': 'b',
    // Greek.
    'Α': 'A', 'Β': 'B', 'Ε': 'E', 'Ζ': 'Z', 'Η': 'H', 'Ι': 'I', 'Κ': 'K',
    'Μ': 'M', 'Ν': 'N', 'Ο': 'O', 'Ρ': 'P', 'Τ': 'T', 'Υ': 'Y', 'Χ': 'X',
    'ο': 'o', 'ν': 'v',
  };
}
