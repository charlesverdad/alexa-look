/// The RAW-item equivalent of grading a plain photo in the batch flow:
/// decode -> prepare -> grade -> encode, sharing the same RAW decode
/// fallback chain as the single-photo RAW import
/// (`lib/core/raw_import.dart`) and the same prepare/grade pipeline as
/// every other photo (`lib/features/photo/photo_processor.dart`).
///
/// [readRawBytes] and [decode] are injected (defaulting to real file I/O and
/// [decodeRawFile]) purely so tests can exercise the wiring — the ordering
/// of steps, progress reporting, and how a decoded outcome becomes graded
/// JPEG bytes — without touching the filesystem or a native/ffmpeg decoder.
/// See `test/batch_raw_processor_test.dart`.
library;

import 'dart:io';
import 'dart:typed_data';

import '../../core/raw_import.dart';
import '../photo/photo_processor.dart';
import 'batch_controller.dart';

Future<Uint8List> _defaultReadRawBytes(String path) => File(path).readAsBytes();

/// Decodes the RAW/DNG file at [path], grades it at [intensity] against
/// [preparedLut], and returns the full-resolution graded JPEG bytes ready to
/// save — the batch flow's whole "one RAW item" pipeline in one call.
///
/// Reports progress via [onProgress] at the same rough milestones as the
/// single-photo RAW import: reading the file, decoding it, preparing the
/// buffers, and grading/encoding.
Future<Uint8List> gradeRawBatchItem({
  required String path,
  required double intensity,
  required PreparedLut preparedLut,
  required BatchProgressCallback onProgress,
  Future<Uint8List> Function(String path) readRawBytes = _defaultReadRawBytes,
  Future<RawDecodeOutcome> Function(Uint8List rawBytes) decode = decodeRawFile,
}) async {
  onProgress(0.05);
  final rawBytes = await readRawBytes(path);
  onProgress(0.15);
  final decoded = await decode(rawBytes);
  onProgress(0.35);
  final prepared = await preparePhotoFromRgba(
    RawPrepareRequest(
      rgbBytes: decoded.rgbBytes,
      width: decoded.width,
      height: decoded.height,
      preparedLut: preparedLut,
      // Batch only ever grades the full-resolution buffer — there's no live
      // slider preview here — so skip building the preview copy nobody
      // looks at, same as the plain-photo batch path.
      buildPreview: false,
    ),
  );
  onProgress(0.6);
  final result = await gradeCachedPhoto(
    PhotoRegradeRequest.full(prepared, intensity),
  );
  onProgress(0.9);
  return result.gradedBytes;
}
