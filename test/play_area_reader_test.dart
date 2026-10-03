import 'dart:io';
import 'dart:math' as math;
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

/// What Vision read in a phone's photo of FNM's charter alone -- an 8E half
/// under a 6, two tokens left in its 100 Fr. places -- its name printed
/// over two lines (CAP188738177176395477.jpg, Nokia C32, 1920 x 1080).
final fnmPhone = [
  line([0.202, 0.212, 0.265, 0.253], 'FNM'),
  line([0.282, 0.225, 0.359, 0.253], 'Ferrovie'),
  line([0.280, 0.255, 0.436, 0.288], 'Nord Milano (HI)'),
  line([0.158, 0.369, 0.259, 0.393], 'Limit 4/3/2'),
  line([0.169, 0.460, 0.218, 0.517], '8E'),
  line([0.344, 0.375, 0.426, 0.393], 'Loks/Trains'),
  line([0.250, 0.447, 0.278, 0.501], '6'),
  line([0.405, 0.457, 0.445, 0.481], '630Fr.'),
  line([0.336, 0.540, 0.349, 0.553], '-'),
  line([0.118, 0.708, 0.132, 0.721], 'Typ'),
  line([0.115, 0.721, 0.132, 0.736], 'Type'),
  line([0.105, 0.762, 0.129, 0.775], '2/28'),
  line([0.102, 0.783, 0.125, 0.796], '3/3H'),
  line([0.099, 0.806, 0.122, 0.819], '4/4H'),
  line([0.092, 0.850, 0.116, 0.866], '5/5H'),
  line([0.086, 0.897, 0.110, 0.910], '6/SH'),
  line([0.078, 0.920, 0.109, 0.935], '8E/8H'),
  line([0.170, 0.618, 0.205, 0.638], ',Rote'),
  line([0.150, 0.713, 0.158, 0.726], '='),
  line([0.174, 0.690, 0.211, 0.703], 'Lok / Train'),
  line([0.179, 0.708, 0.198, 0.721], 'Preis'),
  line([0.177, 0.721, 0.195, 0.734], 'Price'),
  line([0.142, 0.762, 0.153, 0.775], '13'),
  line([0.140, 0.783, 0.147, 0.798], '9'),
  line([0.169, 0.762, 0.195, 0.775], '90/70'),
  line([0.160, 0.785, 0.196, 0.799], '180/150'),
  line([0.157, 0.809, 0.193, 0.822], '300/260'),
  line([0.151, 0.853, 0.189, 0.866], '450/400'),
  line([0.201, 0.876, 0.208, 0.891], '2'),
  line([0.147, 0.897, 0.183, 0.912], '630/550'),
  line([0.141, 0.922, 0.180, 0.938], '960/700'),
  line([0.212, 0.716, 0.230, 0.726], 'Limi'),
  line([0.211, 0.762, 0.221, 0.780], '4'),
  line([0.243, 0.601, 0.420, 0.630], '„Krokodil" Ce 6/8, Baujahr 1921'),
  line([0.238, 0.708, 0.270, 0.718], 'Schrotzet'),
  line([0.244, 0.721, 0.263, 0.734], 'Ruet'),
  line([0.310, 0.713, 0.324, 0.726], 'OR'),
  line([0.237, 0.806, 0.251, 0.822], '2H'),
  line([0.270, 0.785, 0.297, 0.798], '2 › 26'),
  line([0.267, 0.808, 0.295, 0.822], '3› 3H'),
  line([0.430, 0.625, 0.442, 0.646], '+'),
  line([0.228, 0.897, 0.243, 0.912], '3Н'),
  line([0.227, 0.922, 0.241, 0.935], '4H'),
  line([0.260, 0.899, 0.288, 0.915], '+718'),
  line([0.257, 0.922, 0.286, 0.938], '5 , 58'),
  line([0.510, 0.233, 0.531, 0.256], '60'),
  line([0.512, 0.284, 0.538, 0.303], '0 Fr.'),
  line([0.571, 0.233, 0.592, 0.256], '70'),
  line([0.567, 0.281, 0.600, 0.300], '40 Fr.'),
  line([0.638, 0.230, 0.658, 0.256], '80'),
  line([0.631, 0.284, 0.673, 0.303], '100 Fr.'),
  line([0.702, 0.222, 0.719, 0.248], 'FNM'),
  line([0.699, 0.281, 0.740, 0.300], '100 Fr.'),
  line([0.763, 0.284, 0.805, 0.303], '100 Fr.'),
  line([0.469, 0.356, 0.804, 0.377], 'Anzahl der Bahnhofsmarker abhängig vom Ausgabekurs'),
  line([0.468, 0.377, 0.728, 0.398], 'number of station markers depends on PAR'),
  line([0.759, 0.832, 0.769, 0.855], '-'),
];

/// The same, run together the way ML Kit joins things printed in a row:
/// the logo's letters with the name, the token costs into one line, the
/// two train cards' numbers.
List<RecognizedWord> runTogether(List<RecognizedWord> lines) {
  RecognizedWord? find(String text) =>
      lines.where((l) => l.text == text).firstOrNull;
  RecognizedWord joined(List<RecognizedWord> parts) => RecognizedWord(
      parts.map((p) => p.text).join(' '),
      parts.first.left,
      parts.last.right,
      top: parts.map((p) => p.top).reduce(math.min),
      bottom: parts.map((p) => p.bottom).reduce(math.max));
  final costs = [
    for (final l in lines)
      if (l.text.endsWith('Fr.') && l.top > 0.27 && l.top < 0.29) l,
  ]..sort((a, b) => a.left.compareTo(b.left));
  final groups = [
    [find('FNM')!, find('Ferrovie')!],
    costs,
    [find('8E')!, find('6')!],
  ];
  final merged = {for (final g in groups) ...g};
  return [
    for (final l in lines)
      if (!merged.contains(l)) l,
    for (final g in groups) joined(g),
  ];
}

/// What Vision read in an iPhone's photo of Tosa Electric's charter in an
/// 1889 edition, turned upright: three 2 trains, its token places FREE, ¥40
/// and ¥40 -- the last covered by its one token left -- and three of its
/// certificates fanned so each one's strip shows: 2 SHARES 20%, 1 SHARE 10%
/// twice (CAP_408594FA, turned a quarter; 1080 x 1920).
final trPhoto = [
  line([0.044, 0.121, 0.064, 0.137], 'esc'),
  line([0.036, 0.359, 0.054, 0.380], 'tab'),
  line([0.031, 0.483, 0.052, 0.499], 'саp'),
  line([0.025, 0.602, 0.052, 0.625], 'shifi'),
  line([0.084, 0.478, 0.128, 0.571], '2'),
  line([0.297, 0.088, 0.315, 0.111], '80'),
  line([0.163, 0.127, 0.174, 0.142], 'F1'),
  line([0.231, 0.132, 0.243, 0.145], 'F2'),
  line([0.299, 0.134, 0.311, 0.147], 'F3'),
  line([0.368, 0.090, 0.381, 0.114], 'Q'),
  line([0.368, 0.134, 0.379, 0.150], 'F4'),
  line([0.129, 0.201, 0.437, 0.272], 'TOSA ELECTRIC RAIL'),
  line([0.269, 0.341, 0.392, 0.372], 'Trains/Treasury'),
  line([0.288, 0.439, 0.355, 0.532], '2'),
  line([0.453, 0.274, 0.480, 0.289], 'FREE'),
  line([0.504, 0.269, 0.525, 0.289], '·40'),
  line([0.472, 0.450, 0.520, 0.486], '•80'),
  line([0.273, 0.654, 0.288, 0.667], 'S1 BF'),
  line([0.256, 0.672, 0.289, 0.698], 'RUS'),
  line([0.359, 0.667, 0.467, 0.695], 'RUSTED BY 4'),
  line([0.148, 0.685, 0.185, 0.718], 'RUS'),
  line([0.551, 0.189, 0.577, 0.209], 'чаа"'),
  line([0.608, 0.251, 0.619, 0.279], '8'),
  line([0.644, 0.145, 0.656, 0.160], 'F8'),
  line([0.711, 0.147, 0.724, 0.165], 'F9'),
  line([0.778, 0.150, 0.792, 0.165], 'F10'),
  line([0.846, 0.155, 0.860, 0.168], 'F11'),
  line([0.881, 0.222, 0.892, 0.245], '+'),
  line([0.882, 0.266, 0.894, 0.279], '='),
  line([0.648, 0.394, 0.861, 0.447], 'TOSA ELECTRIC RATL'),
  line([0.691, 0.470, 0.825, 0.500], 'PRESIDENT\'S CERTIFICATE'),
  line([0.658, 0.509, 0.734, 0.558], '2SHARES'),
  line([0.807, 0.519, 0.866, 0.576], '20%'),
  line([0.668, 0.645, 0.720, 0.668], 'SHARE'),
  line([0.666, 0.734, 0.728, 0.778], '1SHARE'),
  line([0.817, 0.623, 0.868, 0.674], '10%'),
  line([0.824, 0.726, 0.874, 0.773], '10%'),
  line([0.914, 0.155, 0.930, 0.171], 'F12'),
  line([0.975, 0.271, 0.999, 0.292], 'dele'),
  line([0.980, 0.514, 0.999, 0.530], 'ret'),
  line([0.991, 0.636, 0.999, 0.651], 'S'),
];

/// The same photo turned the other way, upside down: Vision reads it all
/// the same.
final trUpsideDown = [
  line([0.935, 0.860, 0.956, 0.876], 'esc'),
  line([0.946, 0.623, 0.967, 0.641], 'tab'),
  line([0.945, 0.496, 0.969, 0.519], 'cap'),
  line([0.945, 0.377, 0.974, 0.398], 'shifi'),
  line([0.868, 0.424, 0.916, 0.525], '2.'),
  line([0.683, 0.889, 0.703, 0.912], '80'),
  line([0.618, 0.889, 0.629, 0.912], 'Q'),
  line([0.827, 0.855, 0.837, 0.871], 'F1'),
  line([0.689, 0.850, 0.699, 0.866], 'F3'),
  line([0.619, 0.850, 0.631, 0.863], 'F4'),
  line([0.560, 0.729, 0.870, 0.800], 'TOSA ELECTRIC RAIL'),
  line([0.603, 0.628, 0.730, 0.659], 'Trains/Treasury'),
  line([0.750, 0.463, 0.794, 0.556], '2.'),
  line([0.644, 0.468, 0.695, 0.561], '2'),
  line([0.520, 0.708, 0.547, 0.726], 'FREE'),
  line([0.474, 0.711, 0.491, 0.731], '·40'),
  line([0.480, 0.512, 0.526, 0.548], '\$80'),
  line([0.815, 0.313, 0.836, 0.328], 'E2R 1'),
  line([0.814, 0.279, 0.850, 0.313], 'RUST'),
  line([0.711, 0.331, 0.727, 0.346], 'STDE'),
  line([0.709, 0.300, 0.744, 0.328], 'RUS'),
  line([0.549, 0.333, 0.622, 0.349], 'E 150F0MM'),
  line([0.532, 0.305, 0.640, 0.333], 'RUSTED BY 4'),
  line([0.427, 0.788, 0.448, 0.804], 'чEE'),
  line([0.363, 0.388, 0.376, 0.411], 'M'),
  line([0.344, 0.840, 0.356, 0.853], 'F8'),
  line([0.276, 0.837, 0.288, 0.850], 'F9'),
  line([0.206, 0.835, 0.222, 0.848], 'F10'),
  line([0.138, 0.829, 0.153, 0.848], 'F11'),
  line([0.105, 0.757, 0.118, 0.780], '+'),
  line([0.105, 0.718, 0.116, 0.736], '='),
  line([0.228, 0.628, 0.256, 0.643], 'лЕE.'),
  line([0.137, 0.553, 0.352, 0.606], 'TOSA ELECTRIC RAIL'),
  line([0.174, 0.499, 0.307, 0.526], 'PRESIDENT\'S CERTIFICATE'),
  line([0.266, 0.439, 0.340, 0.488], '2SHARES'),
  line([0.131, 0.424, 0.192, 0.481], '20%'),
  line([0.279, 0.333, 0.342, 0.377], '1SHARE'),
  line([0.129, 0.326, 0.180, 0.377], '10%'),
  line([0.276, 0.227, 0.326, 0.240], 'SHARE'),
  line([0.125, 0.230, 0.174, 0.276], '10%'),
  line([0.070, 0.829, 0.086, 0.842], 'F12'),
  line([-0.000, 0.708, 0.023, 0.729], 'dele'),
  line([0.000, 0.470, 0.020, 0.486], 'reti'),
];

/// Uwajima Railroad's charter in the same edition, turned upright: a 6 and
/// a 4, and two of its certificates (CAP_E6EE334F, turned a quarter).
final urPhoto = [
  line([0.119, 0.336, 0.137, 0.349], 'esc'),
  line([0.113, 0.522, 0.132, 0.537], 'tab'),
  line([0.113, 0.616, 0.162, 0.641], 'caps lock'),
  line([0.109, 0.721, 0.137, 0.742], 'shift'),
  line([0.132, 0.775, 0.147, 0.796], 'fn'),
  line([0.214, 0.326, 0.222, 0.339], 'E1'),
  line([0.270, 0.320, 0.279, 0.333], 'F2'),
  line([0.321, 0.282, 0.337, 0.302], '80'),
  line([0.378, 0.276, 0.390, 0.295], 'Q'),
  line([0.324, 0.315, 0.334, 0.328], 'F3'),
  line([0.241, 0.390, 0.475, 0.434], 'UWAJIMA RAILROAD'),
  line([0.259, 0.566, 0.297, 0.638], '6'),
  line([0.350, 0.494, 0.451, 0.522], 'Trains/Treasury'),
  line([0.346, 0.537, 0.385, 0.612], '4'),
  line([0.315, 0.749, 0.334, 0.762], 'HERU'),
  line([0.363, 0.725, 0.456, 0.789], 'RUSTED BYD'),
  line([0.499, 0.444, 0.520, 0.457], 'FREE'),
  line([0.464, 0.580, 0.522, 0.634], '0300'),
  line([0.541, 0.442, 0.557, 0.457], '·40'),
  line([0.847, 0.059, 0.879, 0.093], 'ROnS'),
  line([0.648, 0.251, 0.661, 0.266], 'DD'),
  line([0.650, 0.282, 0.661, 0.295], 'F9'),
  line([0.759, 0.271, 0.770, 0.284], 'F11'),
  line([0.807, 0.233, 0.823, 0.251], '41)'),
  line([0.811, 0.266, 0.824, 0.279], 'F12'),
  line([0.703, 0.276, 0.717, 0.289], 'F10'),
  line([0.792, 0.354, 0.802, 0.367], '='),
  line([0.866, 0.349, 0.897, 0.364], 'delete'),
  line([0.678, 0.459, 0.837, 0.512], 'UWAJIMA RAILROAD'),
  line([0.677, 0.550, 0.725, 0.584], '1SHARE'),
  line([0.686, 0.602, 0.725, 0.625], 'JWATI'),
  line([0.680, 0.690, 0.733, 0.724], '1SHARE'),
  line([0.805, 0.566, 0.843, 0.607], '10%'),
  line([0.810, 0.672, 0.850, 0.705], '10%'),
  line([0.653, 0.756, 0.706, 0.783], 'command'),
  line([0.727, 0.752, 0.760, 0.773], 'option'),
  line([0.882, 0.537, 0.914, 0.553], 'return'),
  line([0.900, 0.633, 0.926, 0.649], 'shift'),
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

  group("a phone's photo of FNM's charter", () {
    void readsFnm(List<RecognizedWord> lines) {
      final reading = PlayAreaReader(title).read(lines, aspect: 1920 / 1080);
      final charter = reading.charters.single;
      expect(charter.company.id, 'FNM');
      expect(charter.trains, ['8E', '6']);
      expect(charter.slots.map((s) => s.cost), [0, 40, 100, 100, 100]);
    }

    test('is read as Vision reads it', () => readsFnm(fnmPhone));

    test('is read with things printed in a row run together', () {
      final merged = runTogether(fnmPhone);
      expect(merged.map((l) => l.text),
          containsAll(['FNM Ferrovie', '8E 6', '0 Fr. 40 Fr. 100 Fr. 100 Fr. 100 Fr.']));
      readsFnm(merged);
    });

    test('a name over two lines finds its company', () {
      final reading = PlayAreaReader(title).read([
        line([0.28, 0.225, 0.36, 0.253], 'Ferrovie'),
        line([0.28, 0.255, 0.44, 0.288], 'Nord Milano (HI)'),
        line([0.25, 0.45, 0.28, 0.50], '6'),
        line([0.5, 0.6, 0.52, 0.61], 'small print'),
        line([0.5, 0.7, 0.52, 0.71], 'more small print'),
      ], aspect: 1920 / 1080);
      expect(reading.charters.single.company.id, 'FNM');
    });
  });

  group("an 1889 edition's charters", () {
    final g1889 = GameTitle.byId('1889')!;

    test('trains from their small print, places from FREE, and shares '
        'from their strips', () {
      final reading = PlayAreaReader(g1889).read(trPhoto, aspect: 1080 / 1920);
      final charter = reading.charters.single;
      expect(charter.company.id, 'TR');
      expect(charter.trains, ['2', '2', '2']);
      // The third place's cost is under its token; the row says it is there.
      expect(charter.slots.map((s) => s.cost), [0, 40, 40]);
      expect(reading.certificates.single.percents, [20, 10, 10]);
      expect(reading.upright, 1);
    });

    test('a photo read upside down is known to be', () {
      final reading =
          PlayAreaReader(g1889).read(trUpsideDown, aspect: 1080 / 1920);
      expect(reading.upright, 0);
    });

    test("a company named a little differently is still found", () {
      // "Uwajima Railroad" on the card, "Uwajima Railway" in tobymao's data;
      // not Awa Railroad, which shares more letters with it.
      final reading = PlayAreaReader(g1889).read(urPhoto, aspect: 1080 / 1920);
      expect(reading.charters.single.company.id, 'UR');
      expect(reading.charters.single.trains, ['6', '4']);
      expect(reading.certificates.single.company.id, 'UR');
      expect(reading.certificates.single.percents, [10, 10]);
    });
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
