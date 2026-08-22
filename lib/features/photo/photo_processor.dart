import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../core/alexa_look.dart' show Color3;
import '../../core/cube_lut.dart';

/// The largest dimension (in pixels) a photo is decoded/graded at for its
/// full-resolution result. Keeps processing time and memory bounded on
/// typical phone photos while still producing a shareable result.
const int kMaxFullResolutionDimension = 3000;

/// The largest dimension a live-preview copy is downscaled to. Small enough
/// that re-grading it on every slider tick feels effectively instant, large
/// enough to look sharp full-screen on a phone.
const int kMaxPreviewDimension = 1200;

/// JPEG quality used for the final, full-resolution save. Phone photos have
/// no alpha to preserve, and JPEG encodes much faster and smaller than PNG.
const int kFullSaveJpegQuality = 95;

/// JPEG quality used for the live preview re-encode — a little lower, since
/// it is redrawn on every slider tick and only ever shown on-screen.
const int kPreviewJpegQuality = 85;

/// Number of isolates to fan a single grade out across: one per extra core
/// (reserving one for the UI/platform thread), clamped to a sane range.
int gradingIsolateCount() =>
    (Platform.numberOfProcessors - 1).clamp(2, 8);

/// Input to [preparePhoto]: the raw picked bytes plus the `.cube` LUT text
/// to parse alongside them, bundled into one object so it can be sent across
/// the isolate boundary in a single message.
class PhotoPrepareRequest {
  final Uint8List originalBytes;
  final String cubeText;

  /// Whether to build the small [kMaxPreviewDimension] preview copy used
  /// for the live intensity-slider preview. The single-photo editor needs
  /// it (that's the whole point of the preview buffer); the batch flow
  /// only ever grades [PhotoRegradeRequest.full] and never shows a live
  /// slider preview, so it passes `false` to skip resizing/copying a
  /// buffer nobody looks at. Defaults to `true`.
  final bool buildPreview;

  const PhotoPrepareRequest({
    required this.originalBytes,
    required this.cubeText,
    this.buildPreview = true,
  });
}

/// The expensive, intensity-independent work done once per picked photo:
/// decoding, orientation baking, downsizing (both full-res and a small
/// preview copy), and LUT parsing.
///
/// Callers should hold onto this and reuse it across every regrade call for
/// the same photo (e.g. as the user drags the intensity slider), instead of
/// redoing decode/resize/parse every time.
class PreparedPhoto {
  /// Full-resolution decoded, orientation-baked, resized image, as
  /// interleaved uint8 RGBA bytes — never mutated in place, so it stays
  /// valid as a source for repeated grading. Used only when saving.
  final Uint8List fullRgbaBytes;
  final int fullWidth;
  final int fullHeight;

  /// A small downscaled copy of the same image (max
  /// [kMaxPreviewDimension] on its longest side), used for the live
  /// intensity-slider preview so re-grading feels instant. Empty (and
  /// [previewWidth]/[previewHeight] zero) when the request was made with
  /// `buildPreview: false`, e.g. from the batch flow, which never grades
  /// this buffer.
  final Uint8List previewRgbaBytes;
  final int previewWidth;
  final int previewHeight;

  /// The LUT lattice, flattened once so every regrade (preview or full) can
  /// reuse it across isolate boundaries without re-parsing the `.cube` text.
  final Float32List lutLattice;
  final int lutSize;
  final Color3 lutDomainMin;
  final Color3 lutDomainMax;

  const PreparedPhoto({
    required this.fullRgbaBytes,
    required this.fullWidth,
    required this.fullHeight,
    required this.previewRgbaBytes,
    required this.previewWidth,
    required this.previewHeight,
    required this.lutLattice,
    required this.lutSize,
    required this.lutDomainMin,
    required this.lutDomainMax,
  });
}

/// Which of a [PreparedPhoto]'s two buffers to grade.
enum PhotoGradeTarget { preview, full }

/// Input to [gradeCachedPhoto]: a previously [preparePhoto]d photo, the
/// intensity to grade it at, and which resolution to grade.
class PhotoRegradeRequest {
  final Uint8List rgbaBytes;
  final int width;
  final int height;
  final Float32List lutLattice;
  final int lutSize;
  final Color3 lutDomainMin;
  final Color3 lutDomainMax;
  final double intensity;
  final PhotoGradeTarget target;

  const PhotoRegradeRequest({
    required this.rgbaBytes,
    required this.width,
    required this.height,
    required this.lutLattice,
    required this.lutSize,
    required this.lutDomainMin,
    required this.lutDomainMax,
    required this.intensity,
    required this.target,
  });

  /// Grades the small preview copy — cheap enough to call on every slider
  /// tick.
  factory PhotoRegradeRequest.preview(PreparedPhoto prepared, double intensity) {
    return PhotoRegradeRequest(
      rgbaBytes: prepared.previewRgbaBytes,
      width: prepared.previewWidth,
      height: prepared.previewHeight,
      lutLattice: prepared.lutLattice,
      lutSize: prepared.lutSize,
      lutDomainMin: prepared.lutDomainMin,
      lutDomainMax: prepared.lutDomainMax,
      intensity: intensity,
      target: PhotoGradeTarget.preview,
    );
  }

  /// Grades the full-resolution copy — only needed once, right before
  /// saving.
  factory PhotoRegradeRequest.full(PreparedPhoto prepared, double intensity) {
    return PhotoRegradeRequest(
      rgbaBytes: prepared.fullRgbaBytes,
      width: prepared.fullWidth,
      height: prepared.fullHeight,
      lutLattice: prepared.lutLattice,
      lutSize: prepared.lutSize,
      lutDomainMin: prepared.lutDomainMin,
      lutDomainMax: prepared.lutDomainMax,
      intensity: intensity,
      target: PhotoGradeTarget.full,
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
  final image = img.bakeOrientation(decoded);

  return _prepareFromImage(image, request.cubeText, request.buildPreview);
}

/// Input to [preparePhotoFromRgba]: an already-decoded RAW photo (see
/// `lib/core/raw_import.dart`), as an interleaved RGB or RGBA buffer plus
/// its dimensions.
class RawPrepareRequest {
  final Uint8List rgbBytes;
  final int width;
  final int height;

  /// Number of channels in [rgbBytes] — 3 (RGB) for a fresh LibRaw/ffmpeg
  /// decode, 4 (RGBA) if the caller already normalized it.
  final int numChannels;
  final String cubeText;
  final bool buildPreview;

  const RawPrepareRequest({
    required this.rgbBytes,
    required this.width,
    required this.height,
    required this.cubeText,
    this.numChannels = 3,
    this.buildPreview = true,
  });
}

/// Like [preparePhoto], but for a RAW photo that's already been decoded to
/// pixels (by LibRaw, ffmpeg, or the embedded-preview fallback — see
/// `lib/core/raw_import.dart`) rather than an encoded JPEG/PNG/etc.
///
/// Skips [img.decodeImage] entirely — the caller's decoder already produced
/// pixels — but otherwise applies the exact same size cap, preview
/// downscale, and LUT parsing as [preparePhoto], so a RAW-sourced and a
/// normally-picked photo end up as equally-shaped [PreparedPhoto]s. Also
/// runs inside [Isolate.run].
Future<PreparedPhoto> preparePhotoFromRgba(RawPrepareRequest request) {
  return Isolate.run(() {
    final image = img.Image.fromBytes(
      width: request.width,
      height: request.height,
      bytes: request.rgbBytes.buffer,
      numChannels: request.numChannels,
      order: request.numChannels == 4
          ? img.ChannelOrder.rgba
          : img.ChannelOrder.rgb,
    );
    return _prepareFromImage(image, request.cubeText, request.buildPreview);
  });
}

/// Shared post-decode work for both [preparePhoto] and
/// [preparePhotoFromRgba]: cap to [kMaxFullResolutionDimension], normalize
/// to 8-bit RGBA, build the preview copy, and parse the LUT.
PreparedPhoto _prepareFromImage(img.Image decoded, String cubeText, bool buildPreview) {
  var image = decoded;

  // Cap the working resolution to keep processing time and memory bounded
  // on typical phone photos while still producing a shareable result.
  if (image.width > kMaxFullResolutionDimension ||
      image.height > kMaxFullResolutionDimension) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? kMaxFullResolutionDimension : null,
      height: image.height > image.width ? kMaxFullResolutionDimension : null,
      interpolation: img.Interpolation.average,
    );
  }

  // Normalize to 8-bit-per-channel RGBA before pulling out raw bytes.
  // Without this, higher-bit-depth sources (e.g. 16-bit PNG/TIFF) hand back
  // raw uint16 sample bytes from getBytes, which the LUT applier would
  // misinterpret as 8-bit RGBA and corrupt.
  image = image.convert(format: img.Format.uint8, numChannels: 4);

  final fullRgbaBytes = image.getBytes(order: img.ChannelOrder.rgba);

  // Build the small preview copy used for the live slider regrade — unless
  // the caller (batch flow) said it will never grade a preview, in which
  // case skip the resize and the extra RGBA buffer copy entirely.
  var previewRgbaBytes = Uint8List(0);
  var previewWidth = 0;
  var previewHeight = 0;
  if (buildPreview) {
    img.Image previewImage = image;
    if (image.width > kMaxPreviewDimension || image.height > kMaxPreviewDimension) {
      previewImage = img.copyResize(
        image,
        width: image.width >= image.height ? kMaxPreviewDimension : null,
        height: image.height > image.width ? kMaxPreviewDimension : null,
        interpolation: img.Interpolation.average,
      );
    }
    previewRgbaBytes = previewImage.getBytes(order: img.ChannelOrder.rgba);
    previewWidth = previewImage.width;
    previewHeight = previewImage.height;
  }

  final lut = CubeLut.parse(cubeText);

  return PreparedPhoto(
    fullRgbaBytes: fullRgbaBytes,
    fullWidth: image.width,
    fullHeight: image.height,
    previewRgbaBytes: previewRgbaBytes,
    previewWidth: previewWidth,
    previewHeight: previewHeight,
    lutLattice: lut.toFloat32Lattice(),
    lutSize: lut.size,
    lutDomainMin: lut.domainMin,
    lutDomainMax: lut.domainMax,
  );
}

/// Encodes an interleaved RGB or RGBA buffer as a JPEG, off the calling
/// isolate. Used to turn a decoded RAW photo's pixels into displayable
/// bytes for the "before" side of the photo editor's before/after toggle
/// (a DNG's own file bytes aren't directly displayable by [Image.memory]).
Future<Uint8List> encodePixelsAsJpeg({
  required Uint8List bytes,
  required int width,
  required int height,
  required int numChannels,
  int quality = kFullSaveJpegQuality,
}) {
  return Isolate.run(() {
    final image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: bytes.buffer,
      numChannels: numChannels,
      order: numChannels == 4 ? img.ChannelOrder.rgba : img.ChannelOrder.rgb,
    );
    return Uint8List.fromList(img.encodeJpg(image, quality: quality));
  });
}

/// Applies the LUT to [request.rgbaBytes] at [request.intensity], splitting
/// the image into horizontal row bands and grading them concurrently across
/// multiple isolates ([gradingIsolateCount] of them), then re-encodes the
/// reassembled result as JPEG.
///
/// This is the cheap, repeatable half of grading: no decode, resize, or LUT
/// parsing, just the pixel math and encode — safe to call on every intensity
/// change once the photo has been [preparePhoto]d.
Future<PhotoGradeResult> gradeCachedPhoto(PhotoRegradeRequest request) async {
  final gradedRgba = await gradeRgbaMulticore(
    rgba: request.rgbaBytes,
    width: request.width,
    height: request.height,
    lattice: request.lutLattice,
    lutSize: request.lutSize,
    domainMin: request.lutDomainMin,
    domainMax: request.lutDomainMax,
    intensity: request.intensity,
  );

  final graded = img.Image.fromBytes(
    width: request.width,
    height: request.height,
    bytes: gradedRgba.buffer,
    order: img.ChannelOrder.rgba,
  );

  final quality = request.target == PhotoGradeTarget.full
      ? kFullSaveJpegQuality
      : kPreviewJpegQuality;
  final jpegBytes = await Isolate.run(
    () => Uint8List.fromList(img.encodeJpg(graded, quality: quality)),
  );

  return PhotoGradeResult(
    gradedBytes: jpegBytes,
    width: request.width,
    height: request.height,
  );
}

/// One horizontal band of an RGBA image to grade in its own isolate.
class _BandJob {
  final Uint8List rgba;
  final Float32List lattice;
  final int lutSize;
  final Color3 domainMin;
  final Color3 domainMax;
  final double intensity;

  const _BandJob({
    required this.rgba,
    required this.lattice,
    required this.lutSize,
    required this.domainMin,
    required this.domainMax,
    required this.intensity,
  });
}

Uint8List _gradeBandSync(_BandJob job) {
  // job.rgba arrived in this isolate as its own copy (isolate messages are
  // deep-copied), so mutating it in place here is safe and never touches the
  // caller's cached buffer.
  CubeLut.applyLutToRgbaBand(
    job.rgba,
    lattice: job.lattice,
    lutSize: job.lutSize,
    domainMin: job.domainMin,
    domainMax: job.domainMax,
    intensity: job.intensity,
  );
  return job.rgba;
}

/// Splits [rgba] (a `width`x`height` RGBA buffer) into horizontal row bands,
/// grades each band concurrently in its own isolate, and reassembles the
/// result — same output as applying the LUT to the whole buffer in one pass,
/// just parallelized across cores.
///
/// The number of bands is [gradingIsolateCount], clamped so a band is never
/// less than one row tall (a very short image just runs on fewer isolates).
Future<Uint8List> gradeRgbaMulticore({
  required Uint8List rgba,
  required int width,
  required int height,
  required Float32List lattice,
  required int lutSize,
  required Color3 domainMin,
  required Color3 domainMax,
  required double intensity,
}) async {
  final bandCount = math.min(gradingIsolateCount(), height).clamp(1, height);
  final bytesPerRow = width * 4;
  final baseRows = height ~/ bandCount;
  final extraRows = height % bandCount;

  final jobs = <Future<Uint8List>>[];
  var startRow = 0;
  for (var band = 0; band < bandCount; band++) {
    // Distribute the remainder rows one-per-band across the first
    // `extraRows` bands so no band is more than one row larger than another.
    final rowsInBand = baseRows + (band < extraRows ? 1 : 0);
    if (rowsInBand == 0) continue;
    final startByte = startRow * bytesPerRow;
    final endByte = (startRow + rowsInBand) * bytesPerRow;
    // Materialize this band's bytes into their own buffer *before* handing
    // them to Isolate.run. A plain sublistView is just a window onto the
    // full image's backing ByteBuffer, and isolate messaging copies the
    // entire backing buffer of a TypedData view (not just the windowed
    // range) — so capturing a view in the closure would serialize the
    // whole image to every band isolate. Copying here first means each
    // isolate receives only its own band.
    final bandBytes =
        Uint8List.fromList(Uint8List.sublistView(rgba, startByte, endByte));
    // Guard against a future regression reintroducing a shared-buffer view:
    // bandBytes must own a buffer sized to exactly this band, not the full
    // image.
    assert(bandBytes.buffer.lengthInBytes == bandBytes.lengthInBytes);
    assert(!identical(bandBytes.buffer, rgba.buffer));
    jobs.add(Isolate.run(() => _gradeBandSync(_BandJob(
          rgba: bandBytes,
          lattice: lattice,
          lutSize: lutSize,
          domainMin: domainMin,
          domainMax: domainMax,
          intensity: intensity,
        ))));
    startRow += rowsInBand;
  }

  final gradedBands = await Future.wait(jobs);

  final out = Uint8List(rgba.length);
  var offset = 0;
  for (final band in gradedBands) {
    out.setRange(offset, offset + band.length, band);
    offset += band.length;
  }
  return out;
}

/// Applies the LUT to the whole [rgba] buffer in a single pass, without
/// splitting into bands or spawning isolates.
///
/// This exists as the correctness reference for [gradeRgbaMulticore] (which
/// must produce byte-identical output, just faster by parallelizing across
/// cores) and as a convenient synchronous path for tests/benchmarks.
Uint8List gradeRgbaSinglePass({
  required Uint8List rgba,
  required Float32List lattice,
  required int lutSize,
  required Color3 domainMin,
  required Color3 domainMax,
  required double intensity,
}) {
  final copy = Uint8List.fromList(rgba);
  CubeLut.applyLutToRgbaBand(
    copy,
    lattice: lattice,
    lutSize: lutSize,
    domainMin: domainMin,
    domainMax: domainMax,
    intensity: intensity,
  );
  return copy;
}
