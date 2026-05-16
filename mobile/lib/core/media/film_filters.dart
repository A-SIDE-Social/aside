import 'dart:ui';

/// A photo filter defined by 6 numeric parameters. Each filter computes a
/// 5×4 color matrix that can be used with [ColorFilter.matrix()] for
/// GPU-accelerated preview and [Paint.colorFilter] for pixel-level export.
///
/// All parameters are designed for easy experimentation — tweak any value
/// and see the result instantly.
class FilmFilter {
  final String id;
  final String name;

  /// Brightness shift. Range: -1 to 1. 0 = no change.
  final double brightness;

  /// Contrast multiplier. Range: 0 to 2. 1 = normal.
  final double contrast;

  /// Saturation multiplier. Range: 0 to 2. 0 = B&W, 1 = normal.
  final double saturation;

  /// Color temperature shift. Range: -1 (cool/blue) to 1 (warm/orange).
  final double temperature;

  /// Green ↔ magenta tint shift. Range: -1 (green) to 1 (magenta).
  final double tint;

  /// Black point lift (fade). Range: 0 to 1. Raises shadows toward gray.
  final double fade;

  /// Film grain intensity. Range: 0 to 1. 0 = no grain, 1 = heavy.
  /// Implemented as a tileable noise texture composited with `softLight`
  /// blend mode — see [FilteredImage] for preview and [applyFilterToImage]
  /// for export. Grain is applied independently of the color matrix.
  final double grain;

  const FilmFilter({
    required this.id,
    required this.name,
    this.brightness = 0,
    this.contrast = 1,
    this.saturation = 1,
    this.temperature = 0,
    this.tint = 0,
    this.fade = 0,
    this.grain = 0,
  });

  /// Whether this is the identity (no-op) filter.
  bool get isNone => id == 'none';

  /// Computes the composite 5×4 color matrix from parameters.
  ///
  /// Transforms are applied in order: brightness → contrast → saturation
  /// → temperature → tint → fade. Each is a 5×4 matrix; they're multiplied
  /// together for the final result.
  List<double> toColorMatrix() {
    var matrix = _identity();

    if (brightness != 0) {
      matrix = _multiply(matrix, _brightnessMatrix(brightness));
    }
    if (contrast != 1) {
      matrix = _multiply(matrix, _contrastMatrix(contrast));
    }
    if (saturation != 1) {
      matrix = _multiply(matrix, _saturationMatrix(saturation));
    }
    if (temperature != 0) {
      matrix = _multiply(matrix, _temperatureMatrix(temperature));
    }
    if (tint != 0) {
      matrix = _multiply(matrix, _tintMatrix(tint));
    }
    if (fade > 0) {
      matrix = _multiply(matrix, _fadeMatrix(fade));
    }

    return matrix;
  }

  /// Returns a [ColorFilter] for use with [ColorFiltered] widget or [Paint].
  ColorFilter toColorFilter() => ColorFilter.matrix(toColorMatrix());

  // ---------------------------------------------------------------------------
  // Matrix builders — each returns a 20-element list (5×4 row-major, last row
  // is the translation/offset row stored in positions 4, 9, 14, 19).
  //
  // Layout:  [ R_r, R_g, R_b, R_a, R_offset,
  //            G_r, G_g, G_b, G_a, G_offset,
  //            B_r, B_g, B_b, B_a, B_offset,
  //            A_r, A_g, A_b, A_a, A_offset ]
  // ---------------------------------------------------------------------------

  static List<double> _identity() => [
        1, 0, 0, 0, 0, //
        0, 1, 0, 0, 0, //
        0, 0, 1, 0, 0, //
        0, 0, 0, 1, 0, //
      ];

  /// Shifts all RGB channels by [b] (−1…1). Offset is in 0–255 space.
  static List<double> _brightnessMatrix(double b) {
    final offset = b * 255;
    return [
      1, 0, 0, 0, offset, //
      0, 1, 0, 0, offset, //
      0, 0, 1, 0, offset, //
      0, 0, 0, 1, 0, //
    ];
  }

  /// Scales RGB around the midpoint (0.5 in normalized space = 127.5 in 0–255).
  static List<double> _contrastMatrix(double c) {
    final offset = 127.5 * (1 - c);
    return [
      c, 0, 0, 0, offset, //
      0, c, 0, 0, offset, //
      0, 0, c, 0, offset, //
      0, 0, 0, 1, 0, //
    ];
  }

  /// Lerps toward luminance. Uses ITU-R BT.601 luma weights.
  static List<double> _saturationMatrix(double s) {
    const lr = 0.2126;
    const lg = 0.7152;
    const lb = 0.0722;
    final sr = (1 - s) * lr;
    final sg = (1 - s) * lg;
    final sb = (1 - s) * lb;
    return [
      sr + s, sg, sb, 0, 0, //
      sr, sg + s, sb, 0, 0, //
      sr, sg, sb + s, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
  }

  /// Shifts color temperature. Positive = warm (boost red, cut blue).
  static List<double> _temperatureMatrix(double t) {
    // Scale to a subtle range — full ±1 would be extreme
    final r = t * 30; // red offset
    final b = -t * 30; // blue offset (opposite)
    return [
      1, 0, 0, 0, r, //
      0, 1, 0, 0, 0, //
      0, 0, 1, 0, b, //
      0, 0, 0, 1, 0, //
    ];
  }

  /// Shifts green ↔ magenta. Positive = magenta (boost red+blue, cut green).
  static List<double> _tintMatrix(double t) {
    final g = -t * 20;
    final rb = t * 10;
    return [
      1, 0, 0, 0, rb, //
      0, 1, 0, 0, g, //
      0, 0, 1, 0, rb, //
      0, 0, 0, 1, 0, //
    ];
  }

  /// Lifts the black point — shadows become gray instead of pure black.
  /// [f] is 0–1. At f=0.1, pure black becomes ~10% gray.
  static List<double> _fadeMatrix(double f) {
    final lift = f * 255;
    final scale = 1 - f;
    return [
      scale, 0, 0, 0, lift, //
      0, scale, 0, 0, lift, //
      0, 0, scale, 0, lift, //
      0, 0, 0, 1, 0, //
    ];
  }

  /// Multiplies two 5×4 matrices (treated as 5×5 with implicit [0,0,0,0,1] row).
  static List<double> _multiply(List<double> a, List<double> b) {
    final result = List<double>.filled(20, 0);
    for (var row = 0; row < 4; row++) {
      for (var col = 0; col < 5; col++) {
        var sum = 0.0;
        for (var k = 0; k < 4; k++) {
          sum += a[row * 5 + k] * b[k * 5 + col];
        }
        // Add the translation component when col == 4
        if (col == 4) {
          sum += a[row * 5 + 4];
        }
        result[row * 5 + col] = sum;
      }
    }
    return result;
  }
}

/// Preset film stock filters. Add new filters by defining parameters —
/// the matrix math handles the rest.
class FilmFilters {
  FilmFilters._();

  static const none = FilmFilter(
    id: 'none',
    name: 'Original',
  );

  /// Punchy warm color — vivid greens, rich skin tones, holiday feel.
  /// Inspired by consumer color negative stocks.
  static const summerPunch = FilmFilter(
    id: 'summer_punch',
    name: 'Summer Punch',
    brightness: 0.03,
    contrast: 1.15,
    saturation: 1.25,
    temperature: 0.15,
    tint: 0.05,
    grain: 0.25,
  );

  /// Warm, slightly desaturated tones with lifted blacks.
  static const warmFade = FilmFilter(
    id: 'warm_fade',
    name: 'Warm Fade',
    brightness: 0.02,
    contrast: 1.05,
    saturation: 0.85,
    temperature: 0.12,
    tint: 0.03,
    fade: 0.025,
    grain: 0.3,
  );

  /// Warm instant-print look — yellow-magenta highlights, milky shadows.
  /// Nostalgic, soft, slightly faded.
  static const instantWarm = FilmFilter(
    id: 'instant_warm',
    name: 'Instant Warm',
    brightness: 0.05,
    contrast: 0.95,
    saturation: 0.85,
    temperature: 0.2,
    tint: 0.08,
    fade: 0.07,
    grain: 0.5,
  );

  /// Cool greens, punchy saturation, everyday color.
  static const coolVivid = FilmFilter(
    id: 'cool_vivid',
    name: 'Cool Vivid',
    contrast: 1.12,
    saturation: 1.1,
    temperature: -0.08,
    tint: -0.04,
    fade: 0.015,
    grain: 0.2,
  );

  /// Cool instant-print look — cyan-green shadows, very milky blacks.
  /// The "found in a shoebox" look.
  static const instantCool = FilmFilter(
    id: 'instant_cool',
    name: 'Instant Cool',
    brightness: 0.04,
    contrast: 0.95,
    saturation: 0.8,
    temperature: -0.1,
    tint: -0.05,
    fade: 0.09,
    grain: 0.55,
  );

  /// High contrast B&W with deep blacks and punchy mids.
  static const hardMono = FilmFilter(
    id: 'hard_mono',
    name: 'Hard Mono',
    brightness: 0.02,
    contrast: 1.3,
    saturation: 0,
    fade: 0.03,
    grain: 0.4,
  );

  /// Softer B&W with lifted shadows and gentle contrast.
  static const softMono = FilmFilter(
    id: 'soft_mono',
    name: 'Soft Mono',
    contrast: 1.15,
    saturation: 0,
    fade: 0.06,
    grain: 0.45,
  );

  /// All available filters in display order. Color filters first (warmest
  /// to coolest), B&W at the end.
  static List<FilmFilter> get all => [
        none,
        summerPunch,
        warmFade,
        instantWarm,
        coolVivid,
        instantCool,
        hardMono,
        softMono,
      ];

  /// Look up a filter by ID (for draft persistence). Returns [none] if not found.
  static FilmFilter byId(String id) {
    return all.firstWhere((f) => f.id == id, orElse: () => none);
  }
}
