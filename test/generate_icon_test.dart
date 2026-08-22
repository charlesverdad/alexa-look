import 'package:flutter_test/flutter_test.dart';

// A relative import into tool/ — this file lives outside lib/ (it's a
// standalone CLI script, not a library other app code depends on), so it
// isn't reachable via a `package:alexa_look/...` URI. Importing it directly
// by relative path lets this test exercise the exact same rendering code
// `dart run tool/generate_icon.dart` uses, with no duplicated logic.
import '../tool/generate_icon.dart';

void main() {
  group('icon generation determinism', () {
    test('renderMainIconPng is byte-identical across two runs', () {
      final first = renderMainIconPng();
      final second = renderMainIconPng();
      expect(first, equals(second));
    });

    test('renderForegroundIconPng is byte-identical across two runs', () {
      final first = renderForegroundIconPng();
      final second = renderForegroundIconPng();
      expect(first, equals(second));
    });

    test('renderBackgroundIconPng is byte-identical across two runs', () {
      final first = renderBackgroundIconPng();
      final second = renderBackgroundIconPng();
      expect(first, equals(second));
    });

    test('the three variants are not accidentally identical to each other', () {
      final main = renderMainIconPng();
      final fg = renderForegroundIconPng();
      final bg = renderBackgroundIconPng();
      expect(main, isNot(equals(fg)));
      expect(main, isNot(equals(bg)));
      expect(fg, isNot(equals(bg)));
    });
  });
}
