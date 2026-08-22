import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:alexa_look/core/lut_generation.dart';
import 'package:alexa_look/core/cube_lut.dart';

void main() {
  group('generateAlexaLookCubeText', () {
    test('is deterministic: two runs produce byte-identical output', () {
      final first = generateAlexaLookCubeText(size: 9);
      final second = generateAlexaLookCubeText(size: 9);
      expect(first, equals(second));
    });

    test('produces a well-formed, parseable .cube for the small size', () {
      final content = generateAlexaLookCubeText(size: 9);
      final lut = CubeLut.parse(content);
      expect(lut.size, 9);
    });

    test('every formatted value has exactly 6 decimal places', () {
      final content = generateAlexaLookCubeText(size: 5);
      final dataLines = content
          .split('\n')
          .where((l) => l.isNotEmpty && !l.startsWith(RegExp(r'[A-Z#]')));
      final valuePattern = RegExp(r'^\d\.\d{6}$');
      for (final line in dataLines) {
        for (final token in line.trim().split(RegExp(r'\s+'))) {
          expect(valuePattern.hasMatch(token), isTrue, reason: 'bad token: $token');
        }
      }
    });

    test('committed assets/luts/alexa_look_33.cube matches a fresh 33-point generation', () {
      final file = File('assets/luts/alexa_look_33.cube');
      if (!file.existsSync()) {
        markTestSkipped('Run `dart run tool/generate_lut.dart` first.');
        return;
      }
      final committed = file.readAsStringSync();
      final fresh = generateAlexaLookCubeText(size: 33);
      expect(committed, equals(fresh));
    });
  });
}
