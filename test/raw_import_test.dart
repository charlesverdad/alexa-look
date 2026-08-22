// Tests for the RAW decode fallback chain's control flow
// (lib/core/raw_import.dart), using injected fake [RawDecodeStep]s so the
// ordering/fallback/all-fail behavior can be verified without touching any
// real decoder (LibRaw's FFI binding, ffmpeg, or file I/O).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:alexa_look/core/raw_import.dart';

RawDecodeOutcome _outcome(RawDecodeSource source) {
  return RawDecodeOutcome(
    rgbBytes: Uint8List(3),
    width: 1,
    height: 1,
    source: source,
  );
}

void main() {
  group('decodeRawFile', () {
    test('uses the first step that succeeds when the primary declines', () async {
      final calls = <String>[];
      final steps = <RawDecodeStep>[
        (bytes) async {
          calls.add('primary');
          return null; // declines — e.g. LibRaw unavailable on this platform.
        },
        (bytes) async {
          calls.add('fallback');
          return _outcome(RawDecodeSource.ffmpeg);
        },
      ];

      final result = await decodeRawFile(Uint8List(0), steps: steps);

      expect(result.source, RawDecodeSource.ffmpeg);
      expect(calls, ['primary', 'fallback']);
    });

    test('uses the next step when the primary throws', () async {
      final calls = <String>[];
      final steps = <RawDecodeStep>[
        (bytes) async {
          calls.add('primary');
          throw Exception('LibRaw reported a decode error');
        },
        (bytes) async {
          calls.add('fallback');
          return _outcome(RawDecodeSource.embeddedPreview);
        },
      ];

      final result = await decodeRawFile(Uint8List(0), steps: steps);

      expect(result.source, RawDecodeSource.embeddedPreview);
      expect(calls, ['primary', 'fallback']);
    });

    test('chain order is respected: a later step is never consulted once an '
        'earlier one succeeds', () async {
      final calls = <String>[];
      final steps = <RawDecodeStep>[
        (bytes) async {
          calls.add('first');
          return _outcome(RawDecodeSource.libraw);
        },
        (bytes) async {
          calls.add('second');
          return _outcome(RawDecodeSource.ffmpeg);
        },
        (bytes) async {
          calls.add('third');
          return _outcome(RawDecodeSource.embeddedPreview);
        },
      ];

      final result = await decodeRawFile(Uint8List(0), steps: steps);

      expect(result.source, RawDecodeSource.libraw);
      expect(calls, ['first']);
    });

    test('throws RawDecodeAllFailedException when every step declines or fails',
        () async {
      final steps = <RawDecodeStep>[
        (bytes) async => null,
        (bytes) async => throw Exception('ffmpeg failed'),
        (bytes) async => null,
      ];

      await expectLater(
        () => decodeRawFile(Uint8List(0), steps: steps),
        throwsA(isA<RawDecodeAllFailedException>()),
      );
    });

    test('RawDecodeAllFailedException collects the thrown steps\' messages', () async {
      final steps = <RawDecodeStep>[
        (bytes) async => throw Exception('boom one'),
        (bytes) async => null,
        (bytes) async => throw Exception('boom two'),
      ];

      try {
        await decodeRawFile(Uint8List(0), steps: steps);
        fail('expected RawDecodeAllFailedException');
      } on RawDecodeAllFailedException catch (e) {
        expect(e.stepErrors.length, 2);
        expect(e.stepErrors[0], contains('boom one'));
        expect(e.stepErrors[1], contains('boom two'));
        expect(e.toString(), contains('boom one'));
      }
    });

    test('an empty chain fails cleanly with no step errors', () async {
      await expectLater(
        () => decodeRawFile(Uint8List(0), steps: const []),
        throwsA(isA<RawDecodeAllFailedException>()),
      );
    });
  });
}
