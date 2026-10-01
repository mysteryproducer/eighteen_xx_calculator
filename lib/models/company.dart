import 'package:flutter/material.dart';

/// A railway company on the board, identified by its station token colour.
///
/// A title the app has data for brings its own companies (see
/// `GameTitle.companies`), with their token colours and home cities; for
/// anything else, companies are just the common token colours, and the user
/// picks whichever matches the company they're calculating for.
class Company {
  final String id;
  final String name;
  final Color color;

  /// The colour of the lettering on the token.
  final Color? textColor;

  /// Where the company's home token goes: a printed hex id, and which city
  /// on it when there is more than one.
  final String? homeHex;
  final int? homeCity;

  const Company({
    required this.id,
    required this.name,
    required this.color,
    this.textColor,
    this.homeHex,
    this.homeCity,
  });

  Company copyWith({String? name}) => Company(
        id: id,
        name: name ?? this.name,
        color: color,
        textColor: textColor,
        homeHex: homeHex,
        homeCity: homeCity,
      );

  /// What to call the company where space is short: its symbol (`BLS`) for
  /// a title's own companies, its name for the plain colours.
  String get label => id.toLowerCase() == name.toLowerCase() ? name : id;

  /// Whether city [city] on hex [hexId] is this company's home.
  bool isHomeOf(String hexId, int city) =>
      homeHex == hexId && (homeCity ?? 0) == city;

  /// A colour as tobymao writes it: `#rrggbb`, `#rgb`, or a CSS name.
  static Color parseColor(String value) {
    var hex = value.trim();
    if (hex.startsWith('#')) {
      hex = hex.substring(1);
      if (hex.length == 3) hex = hex.split('').map((c) => '$c$c').join();
      final rgb = int.tryParse(hex, radix: 16);
      if (hex.length == 6 && rgb != null) return Color(0xFF000000 | rgb);
    }
    return switch (value.trim().toLowerCase()) {
      'white' => const Color(0xFFFFFFFF),
      'black' => const Color(0xFF000000),
      'red' => const Color(0xFFFF0000),
      'green' => const Color(0xFF008000),
      'blue' => const Color(0xFF0000FF),
      'yellow' => const Color(0xFFFFFF00),
      'orange' => const Color(0xFFFFA500),
      'purple' => const Color(0xFF800080),
      'brown' => const Color(0xFFA52A2A),
      'pink' => const Color(0xFFFFC0CB),
      'gold' => const Color(0xFFFFD700),
      'lightblue' => const Color(0xFFADD8E6),
      'darkblue' => const Color(0xFF00008B),
      'lightgreen' => const Color(0xFF90EE90),
      'darkgreen' => const Color(0xFF006400),
      _ => const Color(0xFF808080), // gray, grey, and anything unknown
    };
  }

  /// The default palette: distinct colours that survive being photographed.
  static const List<Company> defaults = [
    Company(id: 'red', name: 'Red', color: Color(0xFFD32F2F)),
    Company(id: 'blue', name: 'Blue', color: Color(0xFF1976D2)),
    Company(id: 'green', name: 'Green', color: Color(0xFF388E3C)),
    Company(id: 'yellow', name: 'Yellow', color: Color(0xFFFBC02D)),
    Company(id: 'orange', name: 'Orange', color: Color(0xFFF57C00)),
    Company(id: 'purple', name: 'Purple', color: Color(0xFF7B1FA2)),
    Company(id: 'black', name: 'Black', color: Color(0xFF212121)),
    Company(id: 'white', name: 'White', color: Color(0xFFFAFAFA)),
  ];

  static Company? byId(String? id, [List<Company> from = defaults]) {
    if (id == null) return null;
    for (final c in from) {
      if (c.id == id) return c;
    }
    return null;
  }
}
