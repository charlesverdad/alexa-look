/// A minimal parser and trilinear-interpolation sampler for Adobe/Iridas
/// `.cube` 3D LUT files, plus a bulk applier for RGB pixel byte buffers.
///
/// Only the subset of the `.cube` format this app actually produces and
/// consumes is supported:
///   - `TITLE "..."` (optional, ignored)
///   - `LUT_3D_SIZE N` (required)
///   - `DOMAIN_MIN r g b` / `DOMAIN_MAX r g b` (optional, default 0/1)
///   - N^3 data lines of `r g b` floating point triples, in the standard
///     `.cube` ordering (red index varies fastest, then green, then blue).
///   - `#` comment lines and blank lines are ignored anywhere.
library;

import 'dart:typed_data';

import 'alexa_look.dart' show Color3;

/// Thrown when a `.cube` file is malformed or uses unsupported features.
class CubeParseException implements Exception {
  final String message;
  CubeParseException(this.message);

  @override
  String toString() => 'CubeParseException: $message';
}

/// A parsed 3D LUT, sampled with trilinear interpolation.
class CubeLut {
  final int size;
  final Float64List _data; // size^3 * 3, indexed [b][g][r][channel]
  final Color3 domainMin;
  final Color3 domainMax;

  CubeLut._(this.size, this._data, this.domainMin, this.domainMax);

  /// Parses the textual contents of a `.cube` file.
  factory CubeLut.parse(String content) {
    int? size;
    Color3 domainMin = const Color3(0, 0, 0);
    Color3 domainMax = const Color3(1, 1, 1);
    final values = <double>[];

    final lines = content.split(RegExp(r'\r\n|\r|\n'));
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      if (line.startsWith('TITLE')) {
        continue;
      }
      if (line.startsWith('LUT_3D_SIZE')) {
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length < 2) {
          throw CubeParseException('Malformed LUT_3D_SIZE line: "$line"');
        }
        size = int.tryParse(parts[1]);
        if (size == null || size < 2) {
          throw CubeParseException('Invalid LUT_3D_SIZE value: "$line"');
        }
        continue;
      }
      if (line.startsWith('DOMAIN_MIN')) {
        domainMin = _parseTriplet(line, 'DOMAIN_MIN');
        continue;
      }
      if (line.startsWith('DOMAIN_MAX')) {
        domainMax = _parseTriplet(line, 'DOMAIN_MAX');
        continue;
      }
      if (line.startsWith('LUT_1D_SIZE')) {
        throw CubeParseException('1D LUTs are not supported.');
      }

      // Otherwise, expect a "r g b" data line.
      final parts =
          line.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
      if (parts.length != 3) {
        throw CubeParseException('Malformed data line: "$line"');
      }
      for (final p in parts) {
        final v = double.tryParse(p);
        if (v == null) {
          throw CubeParseException('Malformed number in data line: "$line"');
        }
        values.add(v);
      }
    }

    if (size == null) {
      throw CubeParseException('Missing required LUT_3D_SIZE directive.');
    }
    final expected = size * size * size * 3;
    if (values.length != expected) {
      throw CubeParseException(
          'Expected $expected data values for LUT_3D_SIZE $size, got '
          '${values.length}.');
    }

    return CubeLut._(
      size,
      Float64List.fromList(values),
      domainMin,
      domainMax,
    );
  }

  static Color3 _parseTriplet(String line, String tag) {
    final parts =
        line.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length != 4) {
      throw CubeParseException('Malformed $tag line: "$line"');
    }
    final vals = parts.sublist(1).map((p) {
      final v = double.tryParse(p);
      if (v == null) {
        throw CubeParseException('Malformed number in $tag line: "$line"');
      }
      return v;
    }).toList();
    return Color3(vals[0], vals[1], vals[2]);
  }

  /// Fetches the raw lattice value at integer indices [ir],[ig],[ib].
  Color3 _lattice(int ir, int ig, int ib) {
    final base = (ib * size * size + ig * size + ir) * 3;
    return Color3(_data[base], _data[base + 1], _data[base + 2]);
  }

  /// Applies the LUT to a single color via trilinear interpolation.
  ///
  /// Input channels are expected in the LUT's domain (by default [0,1]);
  /// values outside the domain are clamped before sampling.
  Color3 apply(double r, double g, double b) {
    final n = size - 1;

    double normalize(double v, double lo, double hi) {
      if (hi <= lo) return 0;
      final t = (v - lo) / (hi - lo);
      return t.clamp(0.0, 1.0);
    }

    final fr = normalize(r, domainMin.r, domainMax.r) * n;
    final fg = normalize(g, domainMin.g, domainMax.g) * n;
    final fb = normalize(b, domainMin.b, domainMax.b) * n;

    final r0 = fr.floor().clamp(0, n);
    final g0 = fg.floor().clamp(0, n);
    final b0 = fb.floor().clamp(0, n);
    final r1 = (r0 + 1).clamp(0, n);
    final g1 = (g0 + 1).clamp(0, n);
    final b1 = (b0 + 1).clamp(0, n);

    final tr = fr - r0;
    final tg = fg - g0;
    final tb = fb - b0;

    final c000 = _lattice(r0, g0, b0);
    final c100 = _lattice(r1, g0, b0);
    final c010 = _lattice(r0, g1, b0);
    final c110 = _lattice(r1, g1, b0);
    final c001 = _lattice(r0, g0, b1);
    final c101 = _lattice(r1, g0, b1);
    final c011 = _lattice(r0, g1, b1);
    final c111 = _lattice(r1, g1, b1);

    double lerp(double a, double b, double t) => a + (b - a) * t;

    Color3 lerpColor(Color3 a, Color3 b, double t) => Color3(
          lerp(a.r, b.r, t),
          lerp(a.g, b.g, t),
          lerp(a.b, b.b, t),
        );

    final c00 = lerpColor(c000, c100, tr);
    final c10 = lerpColor(c010, c110, tr);
    final c01 = lerpColor(c001, c101, tr);
    final c11 = lerpColor(c011, c111, tr);

    final c0 = lerpColor(c00, c10, tg);
    final c1 = lerpColor(c01, c11, tg);

    return lerpColor(c0, c1, tb);
  }

  /// Applies the LUT in place to a buffer of interleaved RGB (or RGBA)
  /// bytes, blending toward the original pixel by [intensity] (0.0 = no
  /// change, 1.0 = fully graded).
  ///
  /// [channelsPerPixel] should be 3 (RGB) or 4 (RGBA, alpha untouched).
  void applyToRgbBytes(
    Uint8List bytes, {
    int channelsPerPixel = 3,
    double intensity = 1.0,
  }) {
    if (channelsPerPixel != 3 && channelsPerPixel != 4) {
      throw ArgumentError.value(
          channelsPerPixel, 'channelsPerPixel', 'must be 3 or 4');
    }
    final clampedIntensity = intensity.clamp(0.0, 1.0);
    final pixelCount = bytes.length ~/ channelsPerPixel;
    for (var i = 0; i < pixelCount; i++) {
      final base = i * channelsPerPixel;
      final r0 = bytes[base] / 255.0;
      final g0 = bytes[base + 1] / 255.0;
      final b0 = bytes[base + 2] / 255.0;
      final graded = apply(r0, g0, b0);
      final r = r0 + (graded.r - r0) * clampedIntensity;
      final g = g0 + (graded.g - g0) * clampedIntensity;
      final b = b0 + (graded.b - b0) * clampedIntensity;
      bytes[base] = (r.clamp(0.0, 1.0) * 255.0).round();
      bytes[base + 1] = (g.clamp(0.0, 1.0) * 255.0).round();
      bytes[base + 2] = (b.clamp(0.0, 1.0) * 255.0).round();
    }
  }

  /// Flattens the lattice data to a [Float32List] in the same `[b][g][r][ch]`
  /// order as the internal storage, for cheap, compact cross-isolate
  /// messaging (a flat typed-data buffer instead of re-sending/re-parsing
  /// the original `.cube` text on every band).
  Float32List toFloat32Lattice() => Float32List.fromList(_data);

  /// Applies a LUT — already flattened via [toFloat32Lattice] — to a buffer
  /// of interleaved RGBA bytes **in place**, blending toward the original
  /// pixel by [intensity] (0.0 = no change, 1.0 = fully graded). Alpha is
  /// left untouched.
  ///
  /// This is the optimized bulk-application path used by the photo grading
  /// pipeline: a single tight loop over the byte buffer with precomputed
  /// scale factors, no [Color3] allocation and no per-pixel function calls
  /// (the trilinear math is written out inline). It is numerically
  /// equivalent (within 1/255 rounding) to calling [apply] pixel-by-pixel
  /// via [applyToRgbBytes], just much faster and allocation-free.
  ///
  /// [rgba] length must be a multiple of 4. [lattice] must be `size^3 * 3`
  /// values long, in the same ordering [toFloat32Lattice] produces.
  static void applyLutToRgbaBand(
    Uint8List rgba, {
    required Float32List lattice,
    required int lutSize,
    required Color3 domainMin,
    required Color3 domainMax,
    double intensity = 1.0,
  }) {
    final n = lutSize - 1;
    if (n <= 0) {
      throw ArgumentError.value(lutSize, 'lutSize', 'must be >= 2');
    }

    // Fold "normalize to [0,1] over the domain, then scale by n" into a
    // single multiply-add per channel: fr = (r - domainMin.r) * scaleR.
    final rangeR = domainMax.r - domainMin.r;
    final rangeG = domainMax.g - domainMin.g;
    final rangeB = domainMax.b - domainMin.b;
    final scaleR = rangeR <= 0 ? 0.0 : n / rangeR;
    final scaleG = rangeG <= 0 ? 0.0 : n / rangeG;
    final scaleB = rangeB <= 0 ? 0.0 : n / rangeB;
    final minR = domainMin.r, minG = domainMin.g, minB = domainMin.b;

    final sizeSq3 = lutSize * lutSize * 3;
    final size3 = lutSize * 3;

    final clampedIntensity = intensity.clamp(0.0, 1.0);
    final nD = n.toDouble();
    final pixelCount = rgba.length ~/ 4;

    for (var i = 0; i < pixelCount; i++) {
      final base = i * 4;
      final r0 = rgba[base] / 255.0;
      final g0 = rgba[base + 1] / 255.0;
      final b0 = rgba[base + 2] / 255.0;

      var fr = (r0 - minR) * scaleR;
      if (fr < 0) {
        fr = 0;
      } else if (fr > nD) {
        fr = nD;
      }
      var fg = (g0 - minG) * scaleG;
      if (fg < 0) {
        fg = 0;
      } else if (fg > nD) {
        fg = nD;
      }
      var fb = (b0 - minB) * scaleB;
      if (fb < 0) {
        fb = 0;
      } else if (fb > nD) {
        fb = nD;
      }

      final ir0 = fr.toInt();
      final ig0 = fg.toInt();
      final ib0 = fb.toInt();
      final ir1 = ir0 < n ? ir0 + 1 : ir0;
      final ig1 = ig0 < n ? ig0 + 1 : ig0;
      final ib1 = ib0 < n ? ib0 + 1 : ib0;

      final tr = fr - ir0;
      final tg = fg - ig0;
      final tb = fb - ib0;

      final ib0Base = ib0 * sizeSq3;
      final ib1Base = ib1 * sizeSq3;
      final ig0Base = ig0 * size3;
      final ig1Base = ig1 * size3;
      final ir0Base = ir0 * 3;
      final ir1Base = ir1 * 3;

      final c000 = ib0Base + ig0Base + ir0Base;
      final c100 = ib0Base + ig0Base + ir1Base;
      final c010 = ib0Base + ig1Base + ir0Base;
      final c110 = ib0Base + ig1Base + ir1Base;
      final c001 = ib1Base + ig0Base + ir0Base;
      final c101 = ib1Base + ig0Base + ir1Base;
      final c011 = ib1Base + ig1Base + ir0Base;
      final c111 = ib1Base + ig1Base + ir1Base;

      final omtr = 1 - tr;
      final omtg = 1 - tg;
      final omtb = 1 - tb;
      final w000 = omtr * omtg * omtb;
      final w100 = tr * omtg * omtb;
      final w010 = omtr * tg * omtb;
      final w110 = tr * tg * omtb;
      final w001 = omtr * omtg * tb;
      final w101 = tr * omtg * tb;
      final w011 = omtr * tg * tb;
      final w111 = tr * tg * tb;

      final gradedR = lattice[c000] * w000 +
          lattice[c100] * w100 +
          lattice[c010] * w010 +
          lattice[c110] * w110 +
          lattice[c001] * w001 +
          lattice[c101] * w101 +
          lattice[c011] * w011 +
          lattice[c111] * w111;
      final gradedG = lattice[c000 + 1] * w000 +
          lattice[c100 + 1] * w100 +
          lattice[c010 + 1] * w010 +
          lattice[c110 + 1] * w110 +
          lattice[c001 + 1] * w001 +
          lattice[c101 + 1] * w101 +
          lattice[c011 + 1] * w011 +
          lattice[c111 + 1] * w111;
      final gradedB = lattice[c000 + 2] * w000 +
          lattice[c100 + 2] * w100 +
          lattice[c010 + 2] * w010 +
          lattice[c110 + 2] * w110 +
          lattice[c001 + 2] * w001 +
          lattice[c101 + 2] * w101 +
          lattice[c011 + 2] * w011 +
          lattice[c111 + 2] * w111;

      var r = r0 + (gradedR - r0) * clampedIntensity;
      var g = g0 + (gradedG - g0) * clampedIntensity;
      var b = b0 + (gradedB - b0) * clampedIntensity;

      if (r < 0) {
        r = 0;
      } else if (r > 1) {
        r = 1;
      }
      if (g < 0) {
        g = 0;
      } else if (g > 1) {
        g = 1;
      }
      if (b < 0) {
        b = 0;
      } else if (b > 1) {
        b = 1;
      }

      rgba[base] = (r * 255.0).round();
      rgba[base + 1] = (g * 255.0).round();
      rgba[base + 2] = (b * 255.0).round();
    }
  }
}
