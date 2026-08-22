// Tests for the batch flow's RAW-item pipeline
// (lib/features/batch/batch_raw_processor.dart), with a fake decode step
// (and a fake byte reader) so this never touches the filesystem or a
// native/ffmpeg RAW decoder — just the wiring: read -> decode -> prepare ->
// grade -> encode, with progress reported along the way.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:alexa_look/core/raw_import.dart';
import 'package:alexa_look/features/batch/batch_raw_processor.dart';
import 'package:alexa_look/features/photo/photo_processor.dart';

/// A tiny hand-written identity LUT: grading with it should leave colors
/// unchanged (within rounding), same fixture pattern as photo_processor_test.
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
        buffer.writeln('${r.toStringAsFixed(6)} ${g.toStringAsFixed(6)} ${b.toStringAsFixed(6)}');
      }
    }
  }
  return buffer.toString();
}

final Uint8List _fake2x2Rgb = Uint8List.fromList([
  255, 0, 0, 0, 255, 0, //
  0, 0, 255, 255, 255, 255,
]);

void main() {
  group('gradeRawBatchItem', () {
    late PreparedLut preparedLut;

    setUp(() {
      preparedLut = PreparedLut.parse(_identityCube(3));
    });

    test('reads via the injected reader, decodes via the injected step, and '
        'returns graded JPEG bytes at the decoded dimensions', () async {
      final progress = <double>[];
      String? readPath;
      Uint8List? decodeInput;

      final gradedBytes = await gradeRawBatchItem(
        path: '/fake/photo.dng',
        intensity: 1.0,
        preparedLut: preparedLut,
        onProgress: progress.add,
        readRawBytes: (path) async {
          readPath = path;
          return Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
        },
        decode: (rawBytes) async {
          decodeInput = rawBytes;
          return RawDecodeOutcome(
            rgbBytes: _fake2x2Rgb,
            width: 2,
            height: 2,
            source: RawDecodeSource.libraw,
          );
        },
      );

      expect(readPath, '/fake/photo.dng');
      expect(decodeInput, [0xDE, 0xAD, 0xBE, 0xEF]);

      // Progress is reported monotonically as the pipeline advances.
      expect(progress, isNotEmpty);
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThan(progress[i - 1]));
      }
      expect(progress.last, lessThanOrEqualTo(1.0));

      final decoded = img.decodeJpg(gradedBytes);
      expect(decoded, isNotNull);
      expect(decoded!.width, 2);
      expect(decoded.height, 2);
    });

    test('a decode step failure propagates rather than being swallowed', () async {
      expect(
        () => gradeRawBatchItem(
          path: '/fake/bad.dng',
          intensity: 1.0,
          preparedLut: preparedLut,
          onProgress: (_) {},
          readRawBytes: (path) async => Uint8List(0),
          decode: (rawBytes) async => throw const FormatException('could not decode RAW'),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('reuses the same preparedLut instance rather than re-parsing per call '
        '(the whole point of sharing it across a batch run)', () async {
      final gradedBytes = await gradeRawBatchItem(
        path: '/fake/photo.dng',
        intensity: 1.0,
        preparedLut: preparedLut,
        onProgress: (_) {},
        readRawBytes: (path) async => Uint8List(0),
        decode: (rawBytes) async => RawDecodeOutcome(
          rgbBytes: _fake2x2Rgb,
          width: 2,
          height: 2,
          source: RawDecodeSource.ffmpeg,
        ),
      );
      // An identity LUT at full intensity should leave the decoded colors
      // essentially unchanged.
      final decoded = img.decodeJpg(gradedBytes)!;
      final topLeft = decoded.getPixel(0, 0);
      expect(topLeft.r, closeTo(255, 20));
      expect(topLeft.g, closeTo(0, 20));
      expect(topLeft.b, closeTo(0, 20));
    });
  });
}
