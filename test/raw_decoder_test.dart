// Tests for lib/core/raw_decoder.dart's platform guard: `flutter test` runs
// on the host (Linux in CI), not Android, so this exercises exactly the
// path real Android devices only take when libcamraw.so somehow fails to
// load — this must never crash, just report the decoder unavailable.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:alexa_look/core/raw_decoder.dart';

void main() {
  group('RawDecoder on a non-Android host', () {
    test('tryLoad() returns null instead of throwing', () {
      expect(() => RawDecoder.tryLoad(), returnsNormally);
      expect(RawDecoder.tryLoad(), isNull);
    });

    test('tryLoad() is idempotent/cached across repeated calls', () {
      final first = RawDecoder.tryLoad();
      final second = RawDecoder.tryLoad();
      expect(first, isNull);
      expect(second, isNull);
    });
  });

  group('RawDecodeFailure', () {
    test('carries the LibRaw error code and describes it', () {
      const failure = RawDecodeFailure(-2);
      expect(failure.libRawErrorCode, -2);
      expect(failure.toString(), contains('-2'));
    });
  });

  group('RawDecodeResult', () {
    test('holds the decoded buffer and dimensions as given', () {
      final rgb = Uint8List(12);
      final result = RawDecodeResult(rgb: rgb, width: 2, height: 2);
      expect(result.rgb, same(rgb));
      expect(result.width, 2);
      expect(result.height, 2);
    });
  });
}
