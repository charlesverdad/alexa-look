import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:alexa_look/core/cube_lut.dart';
import 'package:alexa_look/core/lut_generation.dart';

/// Builds a tiny, hand-written identity LUT of the given [size], so
/// `lut.apply(r,g,b) == (r,g,b)` for any lattice point.
String _identityCube(int size) {
  final buffer = StringBuffer();
  buffer.writeln('TITLE "Identity"');
  buffer.writeln('LUT_3D_SIZE $size');
  final n = size - 1;
  for (var bi = 0; bi < size; bi++) {
    final b = bi / n;
    for (var gi = 0; gi < size; gi++) {
      final g = gi / n;
      for (var ri = 0; ri < size; ri++) {
        final r = ri / n;
        buffer.writeln(
          '${r.toStringAsFixed(6)} ${g.toStringAsFixed(6)} ${b.toStringAsFixed(6)}',
        );
      }
    }
  }
  return buffer.toString();
}

void main() {
  group('CubeLut.parse', () {
    test('parses a small hand-written LUT', () {
      const content = '''
TITLE "Tiny test LUT"
LUT_3D_SIZE 2
DOMAIN_MIN 0.0 0.0 0.0
DOMAIN_MAX 1.0 1.0 1.0
0.0 0.0 0.0
1.0 0.0 0.0
0.0 1.0 0.0
1.0 1.0 0.0
0.0 0.0 1.0
1.0 0.0 1.0
0.0 1.0 1.0
1.0 1.0 1.0
''';
      final lut = CubeLut.parse(content);
      expect(lut.size, 2);
      final c = lut.apply(0.0, 0.0, 0.0);
      expect(c.r, closeTo(0.0, 1e-9));
      expect(c.g, closeTo(0.0, 1e-9));
      expect(c.b, closeTo(0.0, 1e-9));
      final white = lut.apply(1.0, 1.0, 1.0);
      expect(white.r, closeTo(1.0, 1e-9));
      expect(white.g, closeTo(1.0, 1e-9));
      expect(white.b, closeTo(1.0, 1e-9));
    });

    test('ignores comments and blank lines', () {
      const content = '''
# a comment
TITLE "With comments"

LUT_3D_SIZE 2
# another comment
0.0 0.0 0.0
1.0 0.0 0.0
0.0 1.0 0.0
1.0 1.0 0.0
0.0 0.0 1.0
1.0 0.0 1.0
0.0 1.0 1.0
1.0 1.0 1.0
''';
      expect(() => CubeLut.parse(content), returnsNormally);
    });

    test('rejects a file with no LUT_3D_SIZE', () {
      const content = '0.0 0.0 0.0\n1.0 1.0 1.0\n';
      expect(() => CubeLut.parse(content), throwsA(isA<CubeParseException>()));
    });

    test('rejects a data line with the wrong number of values', () {
      const content = '''
LUT_3D_SIZE 2
0.0 0.0 0.0
1.0 0.0
0.0 1.0 0.0
1.0 1.0 0.0
0.0 0.0 1.0
1.0 0.0 1.0
0.0 1.0 1.0
1.0 1.0 1.0
''';
      expect(() => CubeLut.parse(content), throwsA(isA<CubeParseException>()));
    });

    test('rejects a file with too few data values for its declared size', () {
      const content = '''
LUT_3D_SIZE 2
0.0 0.0 0.0
1.0 0.0 0.0
''';
      expect(() => CubeLut.parse(content), throwsA(isA<CubeParseException>()));
    });

    test('rejects non-numeric data', () {
      const content = '''
LUT_3D_SIZE 2
0.0 0.0 0.0
1.0 0.0 x
0.0 1.0 0.0
1.0 1.0 0.0
0.0 0.0 1.0
1.0 0.0 1.0
0.0 1.0 1.0
1.0 1.0 1.0
''';
      expect(() => CubeLut.parse(content), throwsA(isA<CubeParseException>()));
    });
  });

  group('trilinear interpolation', () {
    test('an identity LUT is a no-op within quantization at a 17-point size', () {
      final lut = CubeLut.parse(_identityCube(17));
      for (final v in [0.0, 0.1, 0.33, 0.5, 0.77, 0.9999, 1.0]) {
        final c = lut.apply(v, v, v);
        expect(c.r, closeTo(v, 1 / 16));
        expect(c.g, closeTo(v, 1 / 16));
        expect(c.b, closeTo(v, 1 / 16));
      }
    });

    test('a fine identity LUT is a near-exact no-op', () {
      final lut = CubeLut.parse(_identityCube(33));
      final c = lut.apply(0.37, 0.61, 0.22);
      expect(c.r, closeTo(0.37, 1e-3));
      expect(c.g, closeTo(0.61, 1e-3));
      expect(c.b, closeTo(0.22, 1e-3));
    });

    test('interpolation at a non-lattice point is sane for a non-identity LUT', () {
      // A LUT that inverts (1-x) on every channel.
      const content = '''
LUT_3D_SIZE 2
1.0 1.0 1.0
0.0 1.0 1.0
1.0 0.0 1.0
0.0 0.0 1.0
1.0 1.0 0.0
0.0 1.0 0.0
1.0 0.0 0.0
0.0 0.0 0.0
''';
      final lut = CubeLut.parse(content);
      final mid = lut.apply(0.25, 0.5, 0.75);
      expect(mid.r, closeTo(0.75, 1e-9));
      expect(mid.g, closeTo(0.5, 1e-9));
      expect(mid.b, closeTo(0.25, 1e-9));
    });

    test('out-of-domain input is clamped rather than throwing', () {
      final lut = CubeLut.parse(_identityCube(2));
      expect(() => lut.apply(-1.0, 2.0, 0.5), returnsNormally);
      final c = lut.apply(-1.0, 2.0, 0.5);
      expect(c.r, closeTo(0.0, 1e-9));
      expect(c.g, closeTo(1.0, 1e-9));
      expect(c.b, closeTo(0.5, 1e-9));
    });
  });

  group('applyLutToRgbaBand (optimized bulk path)', () {
    test('matches CubeLut.apply within 1 LSB across random pixels for a '
        'non-trivial LUT', () {
      // Use the real Alexa Look curve (not an identity LUT) so the
      // comparison exercises genuinely non-linear trilinear interpolation,
      // not just a pass-through.
      final lut = CubeLut.parse(generateAlexaLookCubeText(size: 17));
      final lattice = lut.toFloat32Lattice();

      final random = Random(42);
      const pixelCount = 500;
      final rgba = Uint8List(pixelCount * 4);
      for (var i = 0; i < pixelCount; i++) {
        final base = i * 4;
        rgba[base] = random.nextInt(256);
        rgba[base + 1] = random.nextInt(256);
        rgba[base + 2] = random.nextInt(256);
        rgba[base + 3] = 255;
      }
      final reference = Uint8List.fromList(rgba);

      for (final intensity in [0.0, 0.35, 1.0]) {
        final bulk = Uint8List.fromList(rgba);
        CubeLut.applyLutToRgbaBand(
          bulk,
          lattice: lattice,
          lutSize: lut.size,
          domainMin: lut.domainMin,
          domainMax: lut.domainMax,
          intensity: intensity,
        );

        for (var i = 0; i < pixelCount; i++) {
          final base = i * 4;
          final r0 = reference[base] / 255.0;
          final g0 = reference[base + 1] / 255.0;
          final b0 = reference[base + 2] / 255.0;
          final graded = lut.apply(r0, g0, b0);
          final expectedR = (r0 + (graded.r - r0) * intensity).clamp(0.0, 1.0);
          final expectedG = (g0 + (graded.g - g0) * intensity).clamp(0.0, 1.0);
          final expectedB = (b0 + (graded.b - b0) * intensity).clamp(0.0, 1.0);

          expect(bulk[base], closeTo(expectedR * 255.0, 1.0));
          expect(bulk[base + 1], closeTo(expectedG * 255.0, 1.0));
          expect(bulk[base + 2], closeTo(expectedB * 255.0, 1.0));
          // Alpha is untouched.
          expect(bulk[base + 3], 255);
        }
      }
    });

    test('toFloat32Lattice round-trips the same values apply() samples', () {
      final lut = CubeLut.parse(_identityCube(3));
      final lattice = lut.toFloat32Lattice();
      expect(lattice.length, 3 * 3 * 3 * 3);
      // First lattice point (r=0,g=0,b=0) should be black.
      expect(lattice[0], closeTo(0.0, 1e-6));
      expect(lattice[1], closeTo(0.0, 1e-6));
      expect(lattice[2], closeTo(0.0, 1e-6));
    });
  });
}
