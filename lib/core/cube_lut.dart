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
}
