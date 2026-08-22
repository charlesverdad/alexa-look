/// Pure-Dart CLI that grades a single photo through the app's *real*
/// look-processing code path — used to produce the before/after samples in
/// [docs/SAMPLES.md](../docs/SAMPLES.md).
///
/// This intentionally reuses the exact same building blocks the app itself
/// uses for photo grading (see
/// [`lib/features/photo/photo_processor.dart`](../lib/features/photo/photo_processor.dart)):
///
///   - [`CubeLut.parse`](../lib/core/cube_lut.dart) to parse the committed
///     `assets/luts/alexa_look_33.cube` LUT (the same file the app bundles
///     as a Flutter asset).
///   - [`capToMaxDimension`](../lib/core/image_cap.dart) to downscale before
///     grading (same helper, same "never upscale" behavior).
///   - [`CubeLut.applyLutToRgbaBand`](../lib/core/cube_lut.dart) — the
///     optimized bulk RGBA trilinear-interpolation applier with the
///     intensity blend, i.e. the *exact same numeric path* the app's
///     multicore grading (`gradeRgbaMulticore`) fans out across isolates.
///     Running it single-threaded here is numerically identical, just not
///     parallelized — there's no isolate pool needed for a one-shot CLI.
///
/// No `package:flutter` import anywhere in this file or anything it pulls
/// in — only `package:image` (already a pubspec dependency) and `dart:io`.
///
/// Usage:
///   `dart run tool/apply_look.dart <in> <out> [intensity]`
///
/// [intensity] defaults to `1.0` (fully graded). Passing `0.0` runs the
/// identical decode/orientation-bake/resize/encode path with no LUT color
/// change applied at all — that's how the showcase's "before" images are
/// produced, so before/after are byte-for-byte the same processing except
/// for the grade itself.
library;

import 'dart:io';

import 'package:image/image.dart' as img;

import 'package:alexa_look/core/cube_lut.dart';
import 'package:alexa_look/core/image_cap.dart';

/// Matches [kMaxPreviewDimension] in `lib/features/photo/photo_processor.dart`
/// — deliberately smaller than the app's full-resolution save cap (3000px)
/// so the committed showcase images stay small, per docs/SAMPLES.md's size
/// budget.
const int kShowcaseMaxDimension = 1200;

const int kJpegQuality = 85;

const String kDefaultLutPath = 'assets/luts/alexa_look_33.cube';

void main(List<String> args) {
  if (args.length < 2 || args.length > 3) {
    stderr.writeln(
      'Usage: dart run tool/apply_look.dart <in> <out> [intensity]',
    );
    exit(64);
  }

  final inPath = args[0];
  final outPath = args[1];
  final intensity = args.length > 2 ? double.parse(args[2]) : 1.0;

  final inputFile = File(inPath);
  if (!inputFile.existsSync()) {
    stderr.writeln('Input file not found: $inPath');
    exit(66);
  }

  final originalBytes = inputFile.readAsBytesSync();
  final decoded = img.decodeImage(originalBytes);
  if (decoded == null) {
    stderr.writeln('Could not decode image: $inPath');
    exit(65);
  }

  // Same orientation-baking step preparePhoto does, unconditionally.
  final oriented = img.bakeOrientation(decoded);

  // Same resize helper the app's grading pipeline uses, just to a smaller
  // cap so committed showcase media stays small (see kShowcaseMaxDimension).
  final resized = capToMaxDimension(oriented, kShowcaseMaxDimension);

  // Normalize to 8-bit RGBA, exactly like _prepareFromImage does.
  final rgbaImage = resized.convert(format: img.Format.uint8, numChannels: 4);
  final rgbaBytes = rgbaImage.getBytes(order: img.ChannelOrder.rgba);

  final cubeFile = File(kDefaultLutPath);
  if (!cubeFile.existsSync()) {
    stderr.writeln('LUT file not found: $kDefaultLutPath '
        '(run this from the repo root)');
    exit(66);
  }
  final lut = CubeLut.parse(cubeFile.readAsStringSync());

  // The exact same bulk applier the app's gradeRgbaMulticore fans out across
  // isolates (see lib/core/cube_lut.dart) — single-threaded here, but
  // numerically identical output.
  CubeLut.applyLutToRgbaBand(
    rgbaBytes,
    lattice: lut.toFloat32Lattice(),
    lutSize: lut.size,
    domainMin: lut.domainMin,
    domainMax: lut.domainMax,
    intensity: intensity,
  );

  final gradedImage = img.Image.fromBytes(
    width: rgbaImage.width,
    height: rgbaImage.height,
    bytes: rgbaBytes.buffer,
    order: img.ChannelOrder.rgba,
  );

  final jpegBytes = img.encodeJpg(gradedImage, quality: kJpegQuality);
  final outFile = File(outPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsBytesSync(jpegBytes);

  stdout.writeln(
    'Wrote $outPath (${gradedImage.width}x${gradedImage.height}, '
    'intensity=$intensity)',
  );
}
