/// Pure-Dart color science for the "Alexa Look" film emulation.
///
/// This module derives a cinematic look transform entirely from published,
/// generic technical constants:
///  - the sRGB / Rec.709 opto-electronic transfer functions (IEC 61966-2-1),
///  - the published ARRI LogC3 (EI800) encoding curve constants, and
///  - the published ALEXA Wide Gamut (AWG) <-> Rec.709 conversion matrix.
///
/// No ARRI-authored LUTs, presets, or other copyrighted assets are used,
/// embedded, or shipped anywhere in this app. Everything here is re-derived
/// math built from public technical constants, used the way any colorist's
/// custom LUT would be built from a camera's published color science.
///
/// This file has no Flutter dependency so it can be used both by the
/// `tool/generate_lut.dart` command-line LUT generator and by unit tests.
library;

import 'dart:math' as math;

/// A simple immutable RGB triplet used throughout the color pipeline.
class Color3 {
  final double r;
  final double g;
  final double b;

  const Color3(this.r, this.g, this.b);

  Color3 clamped01() => Color3(
        r.clamp(0.0, 1.0),
        g.clamp(0.0, 1.0),
        b.clamp(0.0, 1.0),
      );

  @override
  String toString() => 'Color3(${r.toStringAsFixed(6)}, '
      '${g.toStringAsFixed(6)}, ${b.toStringAsFixed(6)})';

  @override
  bool operator ==(Object other) =>
      other is Color3 && other.r == r && other.g == g && other.b == b;

  @override
  int get hashCode => Object.hash(r, g, b);
}

/// A row-major 3x3 matrix, used for the AWG <-> Rec.709 primary conversion.
class Matrix3 {
  /// Nine values in row-major order: [m00, m01, m02, m10, m11, m12, m20, m21, m22].
  final List<double> m;

  const Matrix3(this.m);

  double at(int row, int col) => m[row * 3 + col];

  /// Applies this matrix to a column vector [c].
  Color3 apply(Color3 c) {
    return Color3(
      at(0, 0) * c.r + at(0, 1) * c.g + at(0, 2) * c.b,
      at(1, 0) * c.r + at(1, 1) * c.g + at(1, 2) * c.b,
      at(2, 0) * c.r + at(2, 1) * c.g + at(2, 2) * c.b,
    );
  }

  double get determinant {
    final a = at(0, 0), b = at(0, 1), c = at(0, 2);
    final d = at(1, 0), e = at(1, 1), f = at(1, 2);
    final g = at(2, 0), h = at(2, 1), i = at(2, 2);
    return a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
  }

  /// Returns the matrix inverse via the classical adjugate method.
  ///
  /// Throws a [StateError] if the matrix is (numerically) singular.
  Matrix3 inverse() {
    final a = at(0, 0), b = at(0, 1), c = at(0, 2);
    final d = at(1, 0), e = at(1, 1), f = at(1, 2);
    final g = at(2, 0), h = at(2, 1), i = at(2, 2);
    final det = determinant;
    if (det.abs() < 1e-12) {
      throw StateError('Matrix3 is singular; cannot invert.');
    }
    final invDet = 1.0 / det;
    return Matrix3([
      (e * i - f * h) * invDet, (c * h - b * i) * invDet, (b * f - c * e) * invDet,
      (f * g - d * i) * invDet, (a * i - c * g) * invDet, (c * d - a * f) * invDet,
      (d * h - e * g) * invDet, (b * g - a * h) * invDet, (a * e - b * d) * invDet,
    ]);
  }
}

/// The published ALEXA Wide Gamut (AWG) -> Rec.709 primary conversion matrix.
///
/// This is a generic, publicly documented color-space conversion matrix (the
/// kind of matrix shipped with any camera's technical color-science
/// documentation so that footage can be converted between working color
/// spaces) — not a proprietary look or LUT.
const Matrix3 awgToRec709Matrix = Matrix3([
  1.61734195, -0.53721545, -0.08028311,
  -0.07040252, 1.33455233, -0.26405072,
  -0.02106408, -0.22695949, 1.24809828,
]);

/// The inverse of [awgToRec709Matrix]: converts linear Rec.709 to linear AWG.
final Matrix3 rec709ToAwgMatrix = awgToRec709Matrix.inverse();

/// The sRGB / Rec.709 electro-optical transfer function (EOTF): converts a
/// display-encoded (gamma) value in roughly [0,1] to scene-linear light.
double srgbEotf(double c) {
  if (c <= 0.04045) {
    return c / 12.92;
  }
  return math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}

/// The sRGB / Rec.709 opto-electronic transfer function (OETF): converts a
/// scene-linear value to a display-encoded (gamma) value.
///
/// Negative input is treated as 0 (this always feeds into a final clamp to
/// [0,1] in the full look pipeline, so the exact sub-zero behavior does not
/// matter for the final image, only that it stays finite and does not throw).
double srgbOetf(double c) {
  if (c <= 0.0) return 0.0;
  if (c <= 0.0031308) {
    return 12.92 * c;
  }
  return 1.055 * math.pow(c, 1 / 2.4).toDouble() - 0.055;
}

double _log10(double x) => math.log(x) / math.ln10;

/// ARRI LogC3 (EI800) encode/decode, using the published curve constants for
/// exposure index 800 ("LogC3", the classic ALEXA log curve family).
///
/// Reference constants (published, generic to the LogC3/EI800 curve):
///   cut = 0.010591, a = 5.555556, b = 0.052272,
///   c = 0.247190, d = 0.385537, e = 5.367655, f = 0.092809.
abstract final class LogC3 {
  static const double cut = 0.010591;
  static const double a = 5.555556;
  static const double b = 0.052272;
  static const double c = 0.247190;
  static const double d = 0.385537;
  static const double e = 5.367655;
  static const double f = 0.092809;

  /// Encodes a scene-linear value into LogC3 (EI800).
  static double encode(double lin) {
    if (lin > cut) {
      return c * _log10(a * lin + b) + d;
    }
    return e * lin + f;
  }

  /// Decodes a LogC3 (EI800) value back to scene-linear.
  ///
  /// The branch threshold is the encoded value of the linear/log crossover
  /// point (`e * cut + f`), matching the branch used by [encode].
  static double decode(double logC) {
    const cutEncoded = e * cut + f;
    if (logC > cutEncoded) {
      return (math.pow(10, (logC - d) / c) - b) / a;
    }
    return (logC - f) / e;
  }
}

/// A monotone cubic Hermite spline (Fritsch-Carlson method), used to build
/// the smooth filmic "print" S-curve from a handful of anchor points while
/// mathematically guaranteeing the curve never decreases between them.
///
/// Beyond the first/last knot, the curve is extrapolated linearly using the
/// boundary tangent, so the curve stays smooth and bounded for out-of-gamut
/// input (e.g. very saturated colors that push a channel outside [0,1]
/// after the AWG matrix).
class MonotoneCubicSpline {
  final List<double> _xs;
  final List<double> _ys;
  final List<double> _ms;

  /// Builds a spline through [knots], which must be sorted by ascending x
  /// with at least 2 points and strictly increasing y (a strictly monotone
  /// increasing curve).
  ///
  /// [tangentScale] lets each interior/endpoint tangent be scaled down from
  /// its Fritsch-Carlson default (still monotone-safe, since shrinking a
  /// tangent only makes the sufficient monotonicity condition easier to
  /// satisfy) to sculpt a softer toe/shoulder. Index 0 corresponds to the
  /// first knot, and so on.
  factory MonotoneCubicSpline(List<(double, double)> knots,
      {List<double>? tangentScale}) {
    assert(knots.length >= 2);
    final xs = knots.map((k) => k.$1).toList();
    final ys = knots.map((k) => k.$2).toList();
    final n = xs.length;
    for (var k = 0; k < n - 1; k++) {
      assert(xs[k + 1] > xs[k], 'knots must have strictly increasing x');
    }

    final d = List<double>.filled(n - 1, 0);
    for (var k = 0; k < n - 1; k++) {
      d[k] = (ys[k + 1] - ys[k]) / (xs[k + 1] - xs[k]);
    }

    final m = List<double>.filled(n, 0);
    m[0] = d[0];
    m[n - 1] = d[n - 2];
    for (var k = 1; k < n - 1; k++) {
      if (d[k - 1] == 0 || d[k] == 0 || d[k - 1].sign != d[k].sign) {
        m[k] = 0;
      } else {
        m[k] = 2 / (1 / d[k - 1] + 1 / d[k]);
      }
    }

    if (tangentScale != null) {
      for (var k = 0; k < n; k++) {
        m[k] *= tangentScale[k];
      }
    }

    // Fritsch-Carlson clipping: guarantees each Hermite segment is monotone
    // given its endpoint tangents, by shrinking any tangent pair whose
    // (alpha, beta) ratio to the secant falls outside the safe region.
    for (var k = 0; k < n - 1; k++) {
      if (d[k] == 0) {
        m[k] = 0;
        m[k + 1] = 0;
        continue;
      }
      final alpha = m[k] / d[k];
      final beta = m[k + 1] / d[k];
      final s = alpha * alpha + beta * beta;
      if (s > 9) {
        final tau = 3 / math.sqrt(s);
        m[k] = tau * alpha * d[k];
        m[k + 1] = tau * beta * d[k];
      }
    }

    return MonotoneCubicSpline._(xs, ys, m);
  }

  MonotoneCubicSpline._(this._xs, this._ys, this._ms);

  double eval(double x) {
    final n = _xs.length;
    if (x <= _xs[0]) {
      return _ys[0] + _ms[0] * (x - _xs[0]);
    }
    if (x >= _xs[n - 1]) {
      return _ys[n - 1] + _ms[n - 1] * (x - _xs[n - 1]);
    }
    var k = 0;
    for (var i = 0; i < n - 1; i++) {
      if (x >= _xs[i] && x <= _xs[i + 1]) {
        k = i;
        break;
      }
    }
    final h = _xs[k + 1] - _xs[k];
    final t = (x - _xs[k]) / h;
    final t2 = t * t;
    final t3 = t2 * t;
    final h00 = 2 * t3 - 3 * t2 + 1;
    final h10 = t3 - 2 * t2 + t;
    final h01 = -2 * t3 + 3 * t2;
    final h11 = t3 - t2;
    return h00 * _ys[k] +
        h10 * h * _ms[k] +
        h01 * _ys[k + 1] +
        h11 * h * _ms[k + 1];
  }
}

/// The full "Alexa Look" pipeline: a smooth, gentle, filmic print emulation
/// built entirely from the generic color-science constants above.
abstract final class AlexaLook {
  // Anchor points for the print S-curve, expressed as (LogC3 value, target
  // "scene-linear-ish" output value) so that after the matrix step and sRGB
  // OETF, the display result lands at chosen target display values:
  //   black (scene-linear 0)   -> ~0.010 display (deep, but not crushed)
  //   mid-gray (scene-linear 0.18, ARRI's reference mid-gray) -> ~0.42 display
  //   white (scene-linear 1.0) -> ~0.97 display (soft, not clipped)
  // Target display values are converted to their pre-OETF equivalent via the
  // sRGB EOTF so the anchor sits exactly where we want it post-OETF.
  static final double _logCBlack = LogC3.encode(0.0);
  static final double _logCMid = LogC3.encode(0.18);
  static final double _logCWhite = LogC3.encode(1.0);

  static final double _yBlack = srgbEotf(0.010);
  static final double _yMid = srgbEotf(0.42);
  static final double _yWhite = srgbEotf(0.97);

  /// The print S-curve, mapping a LogC3 value to a "scene-linear-ish" value
  /// that is then run back through the AWG matrix and sRGB OETF.
  ///
  /// Endpoint tangents are scaled down to 35% of their natural
  /// Fritsch-Carlson value to create a gentle shadow toe and a soft
  /// highlight shoulder, while the interior (mid-gray) tangent is left at
  /// its natural value for a healthy mid-tone contrast boost — a classic
  /// "print film" S shape.
  static final MonotoneCubicSpline _printCurve = MonotoneCubicSpline(
    [
      (_logCBlack, _yBlack),
      (_logCMid, _yMid),
      (_logCWhite, _yWhite),
    ],
    tangentScale: const [0.35, 1.0, 0.35],
  );

  /// Base global desaturation applied by the print/saturation stage.
  static const double _baseSaturation = 0.9;

  /// Rec.709 luma weights, used both for the saturation stage's luma pivot.
  static const double _lumaR = 0.2126;
  static const double _lumaG = 0.7152;
  static const double _lumaB = 0.0722;

  /// Applies the full look to a single display-referred sRGB pixel, with
  /// each channel expected in roughly [0,1] (values outside that range are
  /// handled gracefully but the result is always clamped to [0,1]).
  static Color3 apply(Color3 srgbIn) {
    // 1. Linearize.
    final lin709 = Color3(
      srgbEotf(srgbIn.r),
      srgbEotf(srgbIn.g),
      srgbEotf(srgbIn.b),
    );

    // 2. Rec.709 (linear) -> ALEXA Wide Gamut (linear).
    final linAwg = rec709ToAwgMatrix.apply(lin709);

    // 3. Encode to LogC3 (EI800).
    final logC = Color3(
      LogC3.encode(linAwg.r),
      LogC3.encode(linAwg.g),
      LogC3.encode(linAwg.b),
    );

    // 4a. Filmic "print" S-curve, applied per channel in LogC space.
    final printed = Color3(
      _printCurve.eval(logC.r),
      _printCurve.eval(logC.g),
      _printCurve.eval(logC.b),
    );

    // 4b. Back through the AWG -> Rec.709 matrix.
    final rec709 = awgToRec709Matrix.apply(printed);

    // 4c. Mild saturation treatment: a gentle global desaturation, with
    // extra desaturation for extreme highlights/shadows (a soft filmic
    // "roll-off" of color energy at the tonal extremes).
    final luma =
        _lumaR * rec709.r + _lumaG * rec709.g + _lumaB * rec709.b;
    final highlightDesat = ((luma - 0.75) / 0.25).clamp(0.0, 1.0);
    final shadowDesat = ((0.15 - luma) / 0.15).clamp(0.0, 1.0);
    final extraDesat = math.max(highlightDesat, shadowDesat) * 0.4;
    final satFactor = (_baseSaturation * (1 - extraDesat)).clamp(0.0, 1.0);

    final desaturated = Color3(
      luma + (rec709.r - luma) * satFactor,
      luma + (rec709.g - luma) * satFactor,
      luma + (rec709.b - luma) * satFactor,
    );

    // 4d. Encode back to display-referred sRGB and clamp.
    return Color3(
      srgbOetf(desaturated.r),
      srgbOetf(desaturated.g),
      srgbOetf(desaturated.b),
    ).clamped01();
  }
}
