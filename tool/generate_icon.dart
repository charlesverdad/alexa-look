/// Deterministically renders the Alexa Look app icon assets in pure Dart
/// (no design tool, no external image assets) using package:image.
///
/// Produces three 1024x1024 PNGs under `assets/icon/`:
///   - `icon.png`            — the full icon: charcoal background + motif,
///                              fully opaque (safe for iOS, which requires
///                              icons with no alpha channel; the OS applies
///                              its own corner rounding on both platforms).
///   - `icon_foreground.png` — the same motif alone on a transparent
///                              background, padded well inside Android's
///                              adaptive-icon safe zone so it survives any
///                              mask shape (circle, squircle, rounded square).
///   - `icon_background.png` — a flat charcoal fill, for the Android
///                              adaptive-icon background layer.
///
/// The motif: three vertical rounded ("pill") bars of different heights —
/// a waveform/color-strip evoking a film look — swept with an amber to
/// warm-white to teal gradient, over a softly vignetted charcoal panel.
///
/// Every pixel is computed from fixed integer/double geometry with no
/// randomness, no text rendering, and no wall-clock/environment input, so
/// running this twice produces byte-identical PNGs — verified by
/// `test/generate_icon_test.dart`.
///
/// Run with: `dart run tool/generate_icon.dart`
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

const int kIconSize = 1024;

/// Charcoal background color (matches the app's dark theme background/
/// surface family).
const int _bgR = 0x16, _bgG = 0x18, _bgB = 0x1C;

/// Gradient stop colors swept left -> center -> right across the bars.
const int _amberR = 0xE7, _amberG = 0xB7, _amberB = 0x6B; // warm film amber
const int _warmR = 0xF5, _warmG = 0xF1, _warmB = 0xE6; // warm white
const int _tealR = 0x3F, _tealG = 0xA7, _tealB = 0x9A; // cinematic teal

class _Bar {
  final double centerX;
  final double halfWidth;
  final double top;
  final double bottom;
  const _Bar({
    required this.centerX,
    required this.halfWidth,
    required this.top,
    required this.bottom,
  });
}

/// Builds the three-bar waveform geometry, scaled by [scale] (1.0 = the
/// full-bleed layout used for the main icon) and centered in a
/// [kIconSize]x[kIconSize] canvas. A [scale] < 1.0 shrinks the whole motif
/// toward the center, used for the adaptive-icon foreground so it stays
/// inside the safe zone regardless of which mask shape the launcher applies.
List<_Bar> _buildBars(double scale) {
  const cx = kIconSize / 2;
  const cy = kIconSize / 2;
  final barWidth = 118.0 * scale;
  final gap = 64.0 * scale;
  final heights = [420.0, 620.0, 480.0]; // short, tall (center), medium
  final totalWidth = barWidth * 3 + gap * 2;
  final left = cx - totalWidth / 2;

  final bars = <_Bar>[];
  for (var i = 0; i < 3; i++) {
    final barCenterX = left + barWidth / 2 + i * (barWidth + gap);
    final h = heights[i] * scale;
    bars.add(_Bar(
      centerX: barCenterX,
      halfWidth: barWidth / 2,
      top: cy - h / 2,
      bottom: cy + h / 2,
    ));
  }
  return bars;
}

/// Signed coverage (0..1) of point ([x],[y]) inside the rounded "pill" bar
/// [bar], anti-aliased over roughly a 1px edge.
double _barCoverage(_Bar bar, double x, double y) {
  final dx = x - bar.centerX;
  final capTop = bar.top + bar.halfWidth;
  final capBottom = bar.bottom - bar.halfWidth;
  double dist;
  if (y < capTop) {
    final dy = y - capTop;
    dist = _hypot(dx, dy);
  } else if (y > capBottom) {
    final dy = y - capBottom;
    dist = _hypot(dx, dy);
  } else {
    dist = dx.abs();
  }
  final signedDist = dist - bar.halfWidth; // <0 inside, >0 outside
  if (signedDist <= -0.5) return 1.0;
  if (signedDist >= 0.5) return 0.0;
  return 0.5 - signedDist;
}

double _hypot(double a, double b) {
  return _sqrt(a * a + b * b);
}

double _sqrt(double v) {
  if (v <= 0) return 0;
  // Standard Newton-Raphson sqrt — deterministic, avoids relying on
  // dart:math for this tiny amount of logic (still fine either way; kept
  // explicit for clarity of determinism).
  var x = v;
  var guess = v / 2 == 0 ? v : v / 2;
  for (var i = 0; i < 24; i++) {
    guess = 0.5 * (guess + x / guess);
  }
  return guess;
}

/// Gradient color at horizontal position [x] (in canvas pixels), swept
/// amber -> warm-white -> teal across the bars' horizontal extent
/// [gradientLeft]..[gradientRight].
(int, int, int) _gradientColorAt(double x, double gradientLeft, double gradientRight) {
  final span = gradientRight - gradientLeft;
  final t = span <= 0 ? 0.5 : ((x - gradientLeft) / span).clamp(0.0, 1.0);
  if (t <= 0.5) {
    final localT = t / 0.5;
    return (
      _lerpInt(_amberR, _warmR, localT),
      _lerpInt(_amberG, _warmG, localT),
      _lerpInt(_amberB, _warmB, localT),
    );
  } else {
    final localT = (t - 0.5) / 0.5;
    return (
      _lerpInt(_warmR, _tealR, localT),
      _lerpInt(_warmG, _tealG, localT),
      _lerpInt(_warmB, _tealB, localT),
    );
  }
}

int _lerpInt(int a, int b, double t) => (a + (b - a) * t).round().clamp(0, 255);

/// Renders the raw RGBA pixel buffer shared by the main icon and the
/// foreground variant: the bar motif at [barScale], composited over either
/// an opaque vignetted charcoal background ([transparentBackground] false,
/// used for `icon.png`) or full transparency ([transparentBackground] true,
/// used for `icon_foreground.png`).
Uint8List _renderMotif({required double barScale, required bool transparentBackground}) {
  final bars = _buildBars(barScale);
  final gradientLeft = bars.first.centerX - bars.first.halfWidth;
  final gradientRight = bars.last.centerX + bars.last.halfWidth;

  final bytes = Uint8List(kIconSize * kIconSize * 4);
  const cx = kIconSize / 2;
  const cy = kIconSize / 2;
  // Half-diagonal, for the vignette falloff.
  final maxDist = _sqrt(cx * cx + cy * cy);

  for (var y = 0; y < kIconSize; y++) {
    final fy = y + 0.5;
    for (var x = 0; x < kIconSize; x++) {
      final fx = x + 0.5;
      final offset = (y * kIconSize + x) * 4;

      int r, g, b;
      int a;
      if (transparentBackground) {
        r = 0;
        g = 0;
        b = 0;
        a = 0;
      } else {
        final dist = _hypot(fx - cx, fy - cy) / maxDist;
        // Subtle vignette: full brightness in the center, gently darker at
        // the corners.
        final vignette = 1.0 - 0.22 * (dist * dist);
        r = (_bgR * vignette).round().clamp(0, 255);
        g = (_bgG * vignette).round().clamp(0, 255);
        b = (_bgB * vignette).round().clamp(0, 255);
        a = 255;
      }

      // Accumulate coverage from every bar (bars never overlap, so a simple
      // max is enough) and composite its gradient color over the
      // background/transparency computed above.
      var coverage = 0.0;
      var barR = 0, barG = 0, barB = 0;
      for (final bar in bars) {
        final c = _barCoverage(bar, fx, fy);
        if (c > coverage) {
          coverage = c;
          final color = _gradientColorAt(fx, gradientLeft, gradientRight);
          barR = color.$1;
          barG = color.$2;
          barB = color.$3;
        }
      }

      if (coverage > 0) {
        r = (barR * coverage + r * (1 - coverage)).round().clamp(0, 255);
        g = (barG * coverage + g * (1 - coverage)).round().clamp(0, 255);
        b = (barB * coverage + b * (1 - coverage)).round().clamp(0, 255);
        if (transparentBackground) {
          a = (255 * coverage).round().clamp(0, 255);
        }
      }

      bytes[offset] = r;
      bytes[offset + 1] = g;
      bytes[offset + 2] = b;
      bytes[offset + 3] = a;
    }
  }
  return bytes;
}

img.Image _imageFromRgba(Uint8List rgba) {
  return img.Image.fromBytes(
    width: kIconSize,
    height: kIconSize,
    bytes: rgba.buffer,
    order: img.ChannelOrder.rgba,
  );
}

/// The full icon: charcoal panel + motif, fully opaque. Used as the source
/// `image_path` for `flutter_launcher_icons` (legacy Android icon + iOS).
Uint8List renderMainIconPng() {
  final rgba = _renderMotif(barScale: 1.0, transparentBackground: false);
  return Uint8List.fromList(img.encodePng(_imageFromRgba(rgba)));
}

/// The motif alone, transparent background, scaled to sit well inside the
/// Android adaptive-icon safe zone (roughly the center 60% of the canvas).
Uint8List renderForegroundIconPng() {
  final rgba = _renderMotif(barScale: 0.58, transparentBackground: true);
  return Uint8List.fromList(img.encodePng(_imageFromRgba(rgba)));
}

/// A flat charcoal fill, for the Android adaptive-icon background layer.
Uint8List renderBackgroundIconPng() {
  final bytes = Uint8List(kIconSize * kIconSize * 4);
  for (var i = 0; i < kIconSize * kIconSize; i++) {
    final o = i * 4;
    bytes[o] = _bgR;
    bytes[o + 1] = _bgG;
    bytes[o + 2] = _bgB;
    bytes[o + 3] = 255;
  }
  return Uint8List.fromList(img.encodePng(_imageFromRgba(bytes)));
}

void main() {
  final dir = Directory('assets/icon');
  dir.createSync(recursive: true);

  final main = renderMainIconPng();
  File('${dir.path}/icon.png').writeAsBytesSync(main);
  stdout.writeln('Wrote ${dir.path}/icon.png (${main.length} bytes).');

  final fg = renderForegroundIconPng();
  File('${dir.path}/icon_foreground.png').writeAsBytesSync(fg);
  stdout.writeln('Wrote ${dir.path}/icon_foreground.png (${fg.length} bytes).');

  final bg = renderBackgroundIconPng();
  File('${dir.path}/icon_background.png').writeAsBytesSync(bg);
  stdout.writeln('Wrote ${dir.path}/icon_background.png (${bg.length} bytes).');
}
