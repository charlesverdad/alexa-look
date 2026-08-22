/// Pure generation of the Alexa Look `.cube` file contents, shared by
/// `tool/generate_lut.dart` (which writes it to disk) and the test suite
/// (which checks it is byte-for-byte deterministic).
library;

import 'alexa_look.dart';

/// Generates the full text contents of a `size`^3 Alexa Look `.cube` LUT.
///
/// Deterministic: calling this twice with the same [size] always produces
/// identical output, since it is a pure function of [AlexaLook.apply].
String generateAlexaLookCubeText({int size = 33}) {
  final buffer = StringBuffer();
  buffer.writeln('TITLE "Alexa Look $size"');
  buffer.writeln('LUT_3D_SIZE $size');
  buffer.writeln('DOMAIN_MIN 0.0 0.0 0.0');
  buffer.writeln('DOMAIN_MAX 1.0 1.0 1.0');

  final n = size - 1;
  // Standard .cube ordering: red index varies fastest, then green, then blue.
  for (var bi = 0; bi < size; bi++) {
    final b = bi / n;
    for (var gi = 0; gi < size; gi++) {
      final g = gi / n;
      for (var ri = 0; ri < size; ri++) {
        final r = ri / n;
        final out = AlexaLook.apply(Color3(r, g, b));
        buffer.writeln('${_fmt(out.r)} ${_fmt(out.g)} ${_fmt(out.b)}');
      }
    }
  }

  return buffer.toString();
}

/// Formats a value with exactly 6 decimal places, clamped to [0,1] and with
/// negative-zero normalized to positive zero, so output is byte-for-byte
/// reproducible across runs and platforms.
String _fmt(double v) {
  final clamped = v.clamp(0.0, 1.0);
  final normalized = clamped == 0.0 ? 0.0 : clamped;
  return normalized.toStringAsFixed(6);
}
