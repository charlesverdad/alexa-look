import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:alexa_look/core/cube_lut.dart';
import 'package:alexa_look/core/lut_generation.dart';
import 'package:alexa_look/features/photo/photo_processor.dart';

void main() {
  group('multicore banded grading', () {
    test('gradeRgbaMulticore output is byte-for-byte identical to a single-pass grade', () async {
      final lut = CubeLut.parse(generateAlexaLookCubeText(size: 17));
      final lattice = lut.toFloat32Lattice();

      // A size that won't divide evenly across every possible isolate count
      // (an odd height), so the reassembly logic's remainder handling is
      // actually exercised.
      const width = 37;
      const height = 91;
      final random = Random(7);
      final rgba = Uint8List(width * height * 4);
      for (var i = 0; i < rgba.length; i += 4) {
        rgba[i] = random.nextInt(256);
        rgba[i + 1] = random.nextInt(256);
        rgba[i + 2] = random.nextInt(256);
        rgba[i + 3] = 255;
      }

      final singlePass = gradeRgbaSinglePass(
        rgba: rgba,
        lattice: lattice,
        lutSize: lut.size,
        domainMin: lut.domainMin,
        domainMax: lut.domainMax,
        intensity: 0.7,
      );

      final multicore = await gradeRgbaMulticore(
        rgba: rgba,
        width: width,
        height: height,
        lattice: lattice,
        lutSize: lut.size,
        domainMin: lut.domainMin,
        domainMax: lut.domainMax,
        intensity: 0.7,
      );

      expect(multicore.length, singlePass.length);
      expect(multicore, equals(singlePass));
    });

    test('handles images shorter than the isolate count without error', () async {
      final lut = CubeLut.parse(generateAlexaLookCubeText(size: 9));
      final lattice = lut.toFloat32Lattice();
      const width = 4;
      const height = 1; // fewer rows than gradingIsolateCount() will ever be
      final rgba = Uint8List(width * height * 4);
      for (var i = 0; i < rgba.length; i += 4) {
        rgba[i] = 120;
        rgba[i + 1] = 60;
        rgba[i + 2] = 200;
        rgba[i + 3] = 255;
      }

      final result = await gradeRgbaMulticore(
        rgba: rgba,
        width: width,
        height: height,
        lattice: lattice,
        lutSize: lut.size,
        domainMin: lut.domainMin,
        domainMax: lut.domainMax,
        intensity: 1.0,
      );
      expect(result.length, rgba.length);
    });

    test('preview and full targets both round-trip through gradeCachedPhoto', () async {
      final cubeText = generateAlexaLookCubeText(size: 9);
      // A synthetic "photo": build RGBA bytes directly rather than going
      // through preparePhoto/image decode, to keep this test fast and
      // isolate it to the grading path.
      final prepared = await preparePhoto(
        PhotoPrepareRequest(
          originalBytes: _tinyPngBytes(),
          cubeText: cubeText,
        ),
      );
      final full = await gradeCachedPhoto(PhotoRegradeRequest.full(prepared, 1.0));
      final preview = await gradeCachedPhoto(PhotoRegradeRequest.preview(prepared, 1.0));
      expect(full.gradedBytes, isNotEmpty);
      expect(preview.gradedBytes, isNotEmpty);
    });
  });

  group('performance sanity', () {
    test('the optimized bulk path grades a 1000x1000 image within a generous time bound', () {
      final lut = CubeLut.parse(generateAlexaLookCubeText(size: 33));
      final lattice = lut.toFloat32Lattice();
      const width = 1000;
      const height = 1000;
      final rgba = Uint8List(width * height * 4);
      final random = Random(1);
      for (var i = 0; i < rgba.length; i += 4) {
        rgba[i] = random.nextInt(256);
        rgba[i + 1] = random.nextInt(256);
        rgba[i + 2] = random.nextInt(256);
        rgba[i + 3] = 255;
      }

      final stopwatch = Stopwatch()..start();
      CubeLut.applyLutToRgbaBand(
        rgba,
        lattice: lattice,
        lutSize: lut.size,
        domainMin: lut.domainMin,
        domainMax: lut.domainMax,
        intensity: 1.0,
      );
      stopwatch.stop();

      // Generous bound: this is a JIT-mode test run (flutter test), so it's
      // meant to catch a pathological regression (e.g. an accidental
      // per-pixel allocation or an O(n^2) bug), not to pin exact
      // performance. 1M pixels well under 10 seconds is easily achievable
      // for a tight, allocation-free loop even in JIT.
      expect(stopwatch.elapsedMilliseconds, lessThan(10000));
    });
  });
}

/// A tiny (4x4, mid-gray) PNG, just so [preparePhoto] has something real to
/// decode without pulling in a large fixture file.
Uint8List _tinyPngBytes() {
  final image = img.Image(width: 4, height: 4);
  img.fill(image, color: img.ColorRgb8(128, 128, 128));
  return Uint8List.fromList(img.encodePng(image));
}
