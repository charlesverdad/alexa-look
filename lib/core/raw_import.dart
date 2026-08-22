/// The RAW (DNG) import fallback chain: tries LibRaw first, then an ffmpeg
/// render, then a pure-Dart embedded-JPEG-preview extraction, in that
/// order, stopping at the first one that produces a usable image.
///
/// Every step normalizes its result to the same shape — an interleaved RGB
/// buffer capped to [kMaxFullResolutionDimension] — so callers (see
/// `lib/features/photo/photo_screen.dart`) can hand the outcome straight to
/// [preparePhotoFromRgba] regardless of which decoder actually ran.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/return_code.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../features/photo/photo_processor.dart' show kMaxFullResolutionDimension;
import 'dng_preview.dart';
import 'image_cap.dart';
import 'output_naming.dart';
import 'raw_decoder.dart';

/// Which decoder actually produced a [RawDecodeOutcome] — shown to the user
/// as a small badge in the editor (see `photo_screen.dart`) so they know how
/// faithful the preview is: LibRaw does a real raw demosaic, while the
/// other two just recover/render a preview image already baked in-camera.
enum RawDecodeSource { libraw, ffmpeg, embeddedPreview }

/// The result of a successful [decodeRawFile] call: an interleaved 8-bit RGB
/// buffer (no alpha), already capped to [kMaxFullResolutionDimension] on its
/// longest side, plus which decoder produced it.
class RawDecodeOutcome {
  final Uint8List rgbBytes;
  final int width;
  final int height;
  final RawDecodeSource source;

  const RawDecodeOutcome({
    required this.rgbBytes,
    required this.width,
    required this.height,
    required this.source,
  });
}

/// Thrown by [decodeRawFile] when every step in the chain either declined
/// (returned `null`) or failed (threw) — nothing could turn the file into a
/// displayable image.
class RawDecodeAllFailedException implements Exception {
  /// One message per step that was attempted and threw, in chain order.
  /// Shorter than the number of steps if some steps just declined (returned
  /// `null`) without throwing.
  final List<String> stepErrors;
  const RawDecodeAllFailedException(this.stepErrors);

  @override
  String toString() => 'Could not decode this RAW file — every available '
      'decoder failed or was unavailable.'
      '${stepErrors.isEmpty ? '' : ' (${stepErrors.join('; ')})'}';
}

/// One step in the RAW decode fallback chain: attempts to decode
/// [rawBytes], returning a normalized [RawDecodeOutcome] on success, `null`
/// if this decoder simply isn't available/applicable here (so
/// [decodeRawFile] should silently move on to the next step), or throwing if
/// it was attempted but failed (recorded and also moves on, but surfaced in
/// [RawDecodeAllFailedException] if every step exhausts).
typedef RawDecodeStep = Future<RawDecodeOutcome?> Function(Uint8List rawBytes);

/// The production fallback chain, in priority order: LibRaw (Android only,
/// a real raw demosaic) → ffmpeg render → embedded JPEG preview extraction.
/// Exposed as a plain list (rather than being hardcoded into
/// [decodeRawFile]) so tests can substitute fake steps to exercise the
/// chain's ordering/fallback/all-fail logic without depending on any
/// platform channel or native library.
final List<RawDecodeStep> defaultRawDecodeSteps = [
  libRawDecodeStep,
  ffmpegDecodeStep,
  embeddedPreviewDecodeStep,
];

/// Runs [rawBytes] through [steps] (or [defaultRawDecodeSteps]) in order,
/// returning the first successful [RawDecodeOutcome]. Throws
/// [RawDecodeAllFailedException] if every step declines or fails.
Future<RawDecodeOutcome> decodeRawFile(
  Uint8List rawBytes, {
  List<RawDecodeStep>? steps,
}) async {
  final chain = steps ?? defaultRawDecodeSteps;
  final errors = <String>[];
  for (final step in chain) {
    try {
      final outcome = await step(rawBytes);
      if (outcome != null) return outcome;
    } catch (e) {
      errors.add(e.toString());
    }
  }
  throw RawDecodeAllFailedException(errors);
}

// --- Step 1: LibRaw (native, Android only) ---------------------------------

/// Decodes [rawBytes] via the vendored LibRaw (see
/// `native/libraw/VENDORING.md`) through `lib/core/raw_decoder.dart`'s FFI
/// bindings. Returns `null` (no attempt made) when the native decoder isn't
/// available on this platform/build — the normal, expected outcome on iOS,
/// or on Android if the library somehow failed to load.
Future<RawDecodeOutcome?> libRawDecodeStep(Uint8List rawBytes) async {
  if (RawDecoder.tryLoad() == null) return null;
  return Isolate.run(() => _decodeWithLibRawSync(rawBytes));
}

RawDecodeOutcome _decodeWithLibRawSync(Uint8List rawBytes) {
  final decoder = RawDecoder.tryLoad();
  if (decoder == null) {
    // Shouldn't normally happen (checked before spawning this isolate), but
    // dynamic library loading is per-isolate, so guard against a fresh
    // isolate somehow failing where the caller's check succeeded.
    throw StateError('LibRaw is unavailable in this isolate.');
  }
  // decode() throws RawDecodeFailure on a LibRaw-reported error, which
  // propagates out of this Isolate.run and is recorded by decodeRawFile.
  final result = decoder.decode(rawBytes);
  final capped = _capToRgb(result.rgb, result.width, result.height, numChannels: 3);
  return RawDecodeOutcome(
    rgbBytes: capped.bytes,
    width: capped.width,
    height: capped.height,
    source: RawDecodeSource.libraw,
  );
}

// --- Step 2: ffmpeg render ---------------------------------------------------

/// Renders a single frame of [rawBytes] via ffmpeg (already bundled through
/// `ffmpeg_kit_flutter_new_full` for the video pipeline) and decodes that.
/// ffmpeg's built-in DNG demuxer/decoder doesn't do the same quality
/// demosaic/white-balance work LibRaw does — the result can look flat or
/// dark — but it's a reasonable fallback when the native decoder isn't
/// available. Returns `null` if ffmpeg itself reports failure (e.g. a raw
/// variant it doesn't understand), so the chain moves on to the next step
/// rather than surfacing an ffmpeg-specific error.
Future<RawDecodeOutcome?> ffmpegDecodeStep(Uint8List rawBytes) async {
  final tempDir = await getTemporaryDirectory();
  final base = generateUniqueOutputName();
  final inputPath = '${tempDir.path}/$base.dng';
  final outputPath = '${tempDir.path}/$base.png';

  await File(inputPath).writeAsBytes(rawBytes, flush: true);
  try {
    final command = '-y -i "$inputPath" -frames:v 1 "$outputPath"';
    final session = await FFmpegKit.execute(command);
    final returnCode = await session.getReturnCode();
    if (!ReturnCode.isSuccess(returnCode)) {
      return null;
    }
    final outputFile = File(outputPath);
    if (!await outputFile.exists()) return null;
    final pngBytes = await outputFile.readAsBytes();
    return await Isolate.run(
      () => _decodeEncodedImageSync(pngBytes, RawDecodeSource.ffmpeg),
    );
  } finally {
    unawaited(_deleteBestEffort(inputPath));
    unawaited(_deleteBestEffort(outputPath));
  }
}

Future<void> _deleteBestEffort(String path) async {
  try {
    await File(path).delete();
  } catch (_) {
    // Best-effort temp file cleanup — not worth surfacing a failure for.
  }
}

// --- Step 3: embedded JPEG preview (pure Dart) ------------------------------

/// Extracts and decodes the largest JPEG preview embedded in [rawBytes]'s
/// own TIFF/IFD structure (see `lib/core/dng_preview.dart`) — no native code
/// or platform channel involved, so this is also the only RAW path
/// available on iOS. Returns `null` if the file has no embedded preview
/// LibRaw/ffmpeg-shaped decoders would already have handled.
Future<RawDecodeOutcome?> embeddedPreviewDecodeStep(Uint8List rawBytes) async {
  final jpeg = extractLargestDngPreviewJpeg(rawBytes);
  if (jpeg == null) return null;
  return Isolate.run(
    () => _decodeEncodedImageSync(jpeg, RawDecodeSource.embeddedPreview),
  );
}

// --- Shared decode/cap helpers ----------------------------------------------

RawDecodeOutcome _decodeEncodedImageSync(Uint8List encodedBytes, RawDecodeSource source) {
  final decoded = img.decodeImage(encodedBytes);
  if (decoded == null) {
    throw const FormatException('Could not decode the rendered/preview image.');
  }
  final oriented = img.bakeOrientation(decoded);
  final rgb = oriented.convert(format: img.Format.uint8, numChannels: 3);
  final capped = _capToRgb(
    rgb.getBytes(order: img.ChannelOrder.rgb),
    rgb.width,
    rgb.height,
    numChannels: 3,
  );
  return RawDecodeOutcome(
    rgbBytes: capped.bytes,
    width: capped.width,
    height: capped.height,
    source: source,
  );
}

/// Wraps [bytes] as an [img.Image], caps it to [kMaxFullResolutionDimension]
/// if larger (via [capToMaxDimension]), and returns its pixels back out as a
/// plain RGB buffer — releasing the (possibly much larger, e.g. ~150MB for a
/// 50MP raw) input buffer as soon as this returns.
({Uint8List bytes, int width, int height}) _capToRgb(
  Uint8List bytes,
  int width,
  int height, {
  required int numChannels,
}) {
  final source = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: bytes.buffer,
    bytesOffset: bytes.offsetInBytes,
    numChannels: numChannels,
    order: numChannels == 4 ? img.ChannelOrder.rgba : img.ChannelOrder.rgb,
  );
  final capped = capToMaxDimension(source, kMaxFullResolutionDimension);
  // Every caller of this function (LibRaw's decode, ffmpeg's rendered PNG,
  // the embedded JPEG preview) already normalizes its result to 8-bit RGB
  // before handing bytes here, so skip the conversion pass entirely when
  // there's nothing left to normalize — otherwise this would silently
  // re-copy/re-convert the whole image a second time, for no reason, on
  // every RAW import.
  final rgb = capped.format == img.Format.uint8 && capped.numChannels == 3
      ? capped
      : capped.convert(format: img.Format.uint8, numChannels: 3);
  return (
    bytes: rgb.getBytes(order: img.ChannelOrder.rgb),
    width: rgb.width,
    height: rgb.height,
  );
}
