import 'package:flutter_test/flutter_test.dart';
import 'package:alexa_look/core/alexa_look.dart';

void main() {
  group('sRGB transfer functions', () {
    test('EOTF/OETF are inverses across [0,1]', () {
      for (var i = 0; i <= 100; i++) {
        final x = i / 100.0;
        final roundTrip = srgbOetf(srgbEotf(x));
        expect(roundTrip, closeTo(x, 1e-6));
      }
    });

    test('EOTF(0) == 0 and EOTF(1) == 1', () {
      expect(srgbEotf(0.0), closeTo(0.0, 1e-9));
      expect(srgbEotf(1.0), closeTo(1.0, 1e-9));
    });
  });

  group('LogC3 (EI800)', () {
    test('encode(0.18) is approximately the published reference value', () {
      // ARRI's published LogC3 EI800 white paper example: 18% linear
      // scene-linear gray encodes to approximately 0.391.
      expect(LogC3.encode(0.18), closeTo(0.391, 0.001));
    });

    test('encode/decode roundtrip is accurate above the cut point', () {
      for (final lin in [0.02, 0.05, 0.1, 0.18, 0.5, 1.0, 2.0, 4.0]) {
        final roundTrip = LogC3.decode(LogC3.encode(lin));
        expect(roundTrip, closeTo(lin, 1e-4));
      }
    });

    test('encode/decode roundtrip is accurate below the cut point', () {
      for (final lin in [-0.05, -0.01, 0.0, 0.005, 0.01]) {
        final roundTrip = LogC3.decode(LogC3.encode(lin));
        expect(roundTrip, closeTo(lin, 1e-6));
      }
    });

    test('encode is monotonically non-decreasing', () {
      double? prev;
      for (var i = -200; i <= 800; i++) {
        final lin = i / 200.0;
        final encoded = LogC3.encode(lin);
        if (prev != null) {
          // Allow a hair of tolerance for the tiny (~1e-5) discontinuity
          // inherent to the published, rounded LogC3 constants right at the
          // linear/log segment boundary.
          expect(encoded, greaterThanOrEqualTo(prev - 1e-4));
        }
        prev = encoded;
      }
    });
  });

  group('Matrix3', () {
    test('inverse of a general matrix satisfies M * M^-1 = I', () {
      const m = Matrix3([2, 0, 1, 1, 3, 2, 1, 0, 4]);
      final inv = m.inverse();
      _expectIdentity(m, inv);
    });

    test('AWG <-> Rec.709 matrix inverse satisfies M * M^-1 = I', () {
      final inv = awgToRec709Matrix.inverse();
      _expectIdentity(awgToRec709Matrix, inv);
      // rec709ToAwgMatrix is computed the same way; sanity check it matches.
      for (var i = 0; i < 9; i++) {
        expect(rec709ToAwgMatrix.m[i], closeTo(inv.m[i], 1e-9));
      }
    });

    test('singular matrix throws on inverse', () {
      const m = Matrix3([1, 2, 3, 2, 4, 6, 1, 1, 1]);
      expect(() => m.inverse(), throwsStateError);
    });
  });

  group('MonotoneCubicSpline', () {
    test('passes exactly through its knots', () {
      final spline = MonotoneCubicSpline([(0.0, 0.0), (0.5, 0.3), (1.0, 1.0)]);
      expect(spline.eval(0.0), closeTo(0.0, 1e-9));
      expect(spline.eval(0.5), closeTo(0.3, 1e-9));
      expect(spline.eval(1.0), closeTo(1.0, 1e-9));
    });

    test('is monotonically increasing between and beyond knots', () {
      final spline = MonotoneCubicSpline([(0.0, 0.0), (0.5, 0.3), (1.0, 1.0)]);
      double? prev;
      for (var i = -50; i <= 150; i++) {
        final x = i / 100.0;
        final y = spline.eval(x);
        if (prev != null) {
          expect(y, greaterThanOrEqualTo(prev));
        }
        prev = y;
      }
    });
  });

  group('AlexaLook full pipeline', () {
    Color3 grayResult(double linear) {
      final display = srgbOetf(linear);
      return AlexaLook.apply(Color3(display, display, display));
    }

    test('gray axis stays neutral (R ~= G ~= B)', () {
      for (final lin in [0.0, 0.02, 0.09, 0.18, 0.4, 0.75, 1.0]) {
        final c = grayResult(lin);
        expect((c.r - c.g).abs(), lessThan(1e-3));
        expect((c.g - c.b).abs(), lessThan(1e-3));
        expect((c.r - c.b).abs(), lessThan(1e-3));
      }
    });

    test('gray axis is monotonically increasing', () {
      double? prev;
      for (var i = 0; i <= 200; i++) {
        final lin = i / 200.0;
        final y = grayResult(lin).r;
        if (prev != null) {
          expect(y, greaterThanOrEqualTo(prev - 1e-9));
        }
        prev = y;
      }
    });

    test('pure black stays close to 0', () {
      final c = grayResult(0.0);
      expect(c.r, lessThan(0.05));
      expect(c.g, lessThan(0.05));
      expect(c.b, lessThan(0.05));
    });

    test('pure white stays above 0.95', () {
      final c = grayResult(1.0);
      expect(c.r, greaterThan(0.95));
      expect(c.g, greaterThan(0.95));
      expect(c.b, greaterThan(0.95));
    });

    test('mid-gray (0.18 scene-linear) lands in the target display range', () {
      final c = grayResult(0.18);
      expect(c.r, inInclusiveRange(0.40, 0.46));
      expect(c.g, inInclusiveRange(0.40, 0.46));
      expect(c.b, inInclusiveRange(0.40, 0.46));
    });

    test('all outputs stay within [0,1] across a wide sample of colors', () {
      for (var ri = 0; ri <= 4; ri++) {
        for (var gi = 0; gi <= 4; gi++) {
          for (var bi = 0; bi <= 4; bi++) {
            final c = AlexaLook.apply(Color3(ri / 4, gi / 4, bi / 4));
            expect(c.r, inInclusiveRange(0.0, 1.0));
            expect(c.g, inInclusiveRange(0.0, 1.0));
            expect(c.b, inInclusiveRange(0.0, 1.0));
          }
        }
      }
    });
  });
}

void _expectIdentity(Matrix3 m, Matrix3 inv) {
  for (var r = 0; r < 3; r++) {
    for (var c = 0; c < 3; c++) {
      double sum = 0;
      for (var k = 0; k < 3; k++) {
        sum += m.at(r, k) * inv.at(k, c);
      }
      expect(sum, closeTo(r == c ? 1.0 : 0.0, 1e-6));
    }
  }
}
