import 'package:flutter_test/flutter_test.dart';

import 'package:alexa_look/core/output_naming.dart';

void main() {
  group('generateUniqueOutputName', () {
    test('matches the alexa_look_<yyyyMMdd_HHmmss>_<suffix> shape', () {
      final now = DateTime(2026, 8, 22, 9, 5, 3);
      final name = generateUniqueOutputName(now: now);
      expect(name, startsWith('alexa_look_20260822_090503_'));
      expect(
        RegExp(r'^alexa_look_\d{8}_\d{6}_[0-9a-f]{8}$').hasMatch(name),
        isTrue,
        reason: 'unexpected shape: $name',
      );
    });

    test('produces no collisions across many names generated at the same instant', () {
      final now = DateTime(2026, 8, 22, 9, 5, 3);
      final names = <String>{
        for (var i = 0; i < 5000; i++) generateUniqueOutputName(now: now),
      };
      expect(names.length, 5000);
    });

    test('produces no collisions when called back-to-back with the real clock '
        '(same-instant batch save scenario)', () {
      final names = <String>{
        for (var i = 0; i < 2000; i++) generateUniqueOutputName(),
      };
      expect(names.length, 2000);
    });
  });

  group('formatTimestampForFilename', () {
    test('zero-pads every field', () {
      final formatted = formatTimestampForFilename(DateTime(2026, 1, 2, 3, 4, 5));
      expect(formatted, '20260102_030405');
    });
  });
}
