/// Generates `assets/luts/alexa_look_33.cube`, a 33-point 3D LUT baking in
/// the Alexa Look transform defined in `lib/core/alexa_look.dart`.
///
/// This is a pure, deterministic function of the color math in that file:
/// running it twice produces byte-identical output, which CI enforces by
/// regenerating the LUT and diffing it against the committed file.
///
/// Run with: `dart run tool/generate_lut.dart`
library;

import 'dart:io';

import 'package:alexa_look/core/lut_generation.dart';

const int lutSize = 33;
const String outputPath = 'assets/luts/alexa_look_33.cube';

void main() {
  final content = generateAlexaLookCubeText(size: lutSize);
  final file = File(outputPath);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
  stdout.writeln(
    'Wrote $outputPath ($lutSize^3 = ${lutSize * lutSize * lutSize} entries).',
  );
}
