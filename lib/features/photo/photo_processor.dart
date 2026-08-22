import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../core/cube_lut.dart';

/// Input to [preparePhoto]: the raw picked bytes plus the `.cube` LUT text
/// to parse alongside them, bundled into one object so it can be sent across
/// the isolate boundary in a single message.
class PhotoPrepareRequest {
  final Uint8List originalBytes;
  final String cubeText;

  const PhotoPrepareRequest({
    required this.originalBytes,
    required this.cubeText,
  });
}

/// The expensive, intensity-independent work done once per picked photo:
/// decoding, orientation baking, downsizing, and LUT parsing.
///
/// Callers should hold onto this and reuse it across every [gradeCachedPhoto]
/// call for the same photo (e.g. as the user drags the intensity slider),
/// instead of redoing decode/resize/parse on every regrade.
class PreparedPhoto {
  /// Decoded, orientation-baked, resized image, as interleaved uint8 RGBA
  /// bytes — never mutated in place, so it stays valid as a source for
  /// repeated grading.
  final Uint8List rgbaBytes;
  final int width;
  final int height;
  final CubeLut lut;

  const PreparedPhoto({
    required this.rgbaBytes,
    required this.width,
    required this.height,
    required this.lut,
  });
}

/// Input to [gradeCachedPhoto]: a previously [preparePhoto]d photo plus the
/// intensity to grade it at.
class PhotoRegradeRequest {
  final Uint8List rgbaBytes;
  final int width;
  final int height;
  final CubeLut lut;
  final double intensity;

  const PhotoRegradeRequest({
    required this.rgbaBytes,
    required this.width,
    required this.height,
    required this.lut,
    required this.intensity,
  });

  factory PhotoRegradeRequest.from(PreparedPhoto prepared, double intensity) {
    return PhotoRegradeRequest(
      rgbaBytes: prepared.rgbaBytes,
      width: prepared.width,
      height: prepared.height,
      lut: prepared.lut,
      intensity: intensity,
    );
  }
}

/// Result of grading: the graded image, re-encoded to bytes in a common
/// format ready for preview/display and saving.
class PhotoGradeResult {
  final Uint8List gradedBytes;
  final int width;
  final int height;

  const PhotoGradeResult({
    required this.gradedBytes,
    required this.width,
    required this.height,
  });
}

/// Decodes [request.originalBytes] and parses [request.cubeText], doing all
/// of the work that only needs to happen once per picked photo regardless of
/// how many times it gets regraded at different intensities.
///
/// Runs in a background isolate via [Isolate.run] so the UI thread never
/// blocks on it.
Future<PreparedPhoto> preparePhoto(PhotoPrepareRequest request) {
  return Isolate.run(() => _preparePhotoSync(request));
}

PreparedPhoto _preparePhotoSync(PhotoPrepareRequest request) {
  final decoded = img.decodeImage(request.originalBytes);
  if (decoded == null) {
    throw const FormatException('Could not decode the selected image.');
  }

  // Bake any EXIF orientation into the pixel data unconditionally. Some
  // downstream steps (like copyResize, below the size cap) also bake
  // orientation as a side effect, but only when they actually run — doing it
  // here up front guarantees every photo is corrected, not just large ones.
  var image = img.bakeOrientation(decoded);

  // Cap the working resolution to keep processing time and memory bounded
  // on typical phone photos while still producing a shareable result.
  const maxDimension = 3000;
  if (image.width > maxDimension || image.height > maxDimension) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? maxDimension : null,
      height: image.height > image.width ? maxDimension : null,
      interpolation: img.Interpolation.average,
    );
  }

  // Normalize to 8-bit-per-channel RGBA before pulling out raw bytes.
  // Without this, higher-bit-depth sources (e.g. 16-bit PNG/TIFF) hand back
  // raw uint16 sample bytes from getBytes, which applyToRgbBytes would
  // misinterpret as 8-bit RGBA and corrupt.
  image = image.convert(format: img.Format.uint8, numChannels: 4);

  final rgbaBytes = image.getBytes(order: img.ChannelOrder.rgba);
  final lut = CubeLut.parse(request.cubeText);

  return PreparedPhoto(
    rgbaBytes: rgbaBytes,
    width: image.width,
    height: image.height,
    lut: lut,
  );
}

/// Applies [request.lut] to [request.rgbaBytes] at [request.intensity] and
/// re-encodes the result as PNG.
///
/// This is the cheap, repeatable half of grading: no decode, resize, or LUT
/// parsing, just the pixel math and encode — safe to call on every intensity
/// change once the photo has been [preparePhoto]d.
///
/// Runs in a background isolate via [Isolate.run] so the UI thread never
/// blocks on it.
Future<PhotoGradeResult> gradeCachedPhoto(PhotoRegradeRequest request) {
  return Isolate.run(() => _gradeCachedPhotoSync(request));
}

PhotoGradeResult _gradeCachedPhotoSync(PhotoRegradeRequest request) {
  // request.rgbaBytes arrived in this isolate as its own copy (isolate
  // messages are deep-copied), so mutating it in place here is safe and
  // never touches the caller's cached original.
  final rgbaBytes = request.rgbaBytes;
  request.lut.applyToRgbBytes(
    rgbaBytes,
    channelsPerPixel: 4,
    intensity: request.intensity,
  );
  final graded = img.Image.fromBytes(
    width: request.width,
    height: request.height,
    bytes: rgbaBytes.buffer,
    order: img.ChannelOrder.rgba,
  );

  final pngBytes = Uint8List.fromList(img.encodePng(graded));
  return PhotoGradeResult(
    gradedBytes: pngBytes,
    width: request.width,
    height: request.height,
  );
}
