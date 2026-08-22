/// Classifies picked/shared files by CONTENT (magic bytes) rather than by
/// which picker produced them (image_picker, file_picker, or a share
/// intent) — so routing decisions (see `lib/core/media_routing.dart`) are
/// driven by what a file actually *is*, not by which UI affordance the user
/// happened to use to select it.
///
/// Only a small leading prefix of each file is inspected — [kSniffHeaderBytes]
/// is comfortably enough for every magic-byte signature this app looks for,
/// including a phone DNG's IFD0 (see [isDngVersionTagPresent]) — so
/// classifying even a large video never requires reading it into memory.
library;

import 'dart:io';
import 'dart:typed_data';

import 'dng_preview.dart' show isDngVersionTagPresent;

/// The specific file format detected, either from content or (when content
/// sniffing is inconclusive) from the file's extension.
enum MediaFormat {
  jpeg,
  png,
  heic,
  webp,
  tiff,
  dng,
  mp4,
  quicktime,
  matroska,
  avi,
  unknown;

  /// The broad handling category routing decisions care about.
  MediaCategory get category => switch (this) {
        MediaFormat.jpeg ||
        MediaFormat.png ||
        MediaFormat.heic ||
        MediaFormat.webp ||
        MediaFormat.tiff =>
          MediaCategory.photo,
        MediaFormat.dng => MediaCategory.raw,
        MediaFormat.mp4 ||
        MediaFormat.quicktime ||
        MediaFormat.matroska ||
        MediaFormat.avi =>
          MediaCategory.video,
        MediaFormat.unknown => MediaCategory.unsupported,
      };
}

/// How a [MediaFormat] should be handled by the rest of the app.
enum MediaCategory { photo, raw, video, unsupported }

/// The outcome of classifying one file: its [format]/[category], and
/// whether that was decided by content sniffing or (only when sniffing was
/// inconclusive) by falling back to the file's extension.
class MediaDetectionResult {
  final MediaFormat format;
  final bool byExtensionFallback;

  const MediaDetectionResult(this.format, {this.byExtensionFallback = false});

  MediaCategory get category => format.category;

  @override
  String toString() =>
      'MediaDetectionResult($format${byExtensionFallback ? ', by extension' : ''})';
}

/// How many leading bytes of a file are read to classify it. Generous for
/// every signature this app checks (including a phone DNG's IFD0 entry
/// table), while still tiny next to a multi-hundred-MB video.
const int kSniffHeaderBytes = 65536;

/// Classifies file content already in memory as [header] — the file's
/// leading bytes; it need not be the whole file, just at least
/// [kSniffHeaderBytes] worth (or the whole file if smaller). [path], if
/// given, is used only as a fallback when content sniffing can't determine
/// a format at all.
MediaDetectionResult classifyMediaBytes(Uint8List header, {String? path}) {
  final sniffed = _sniff(header);
  if (sniffed != null) return MediaDetectionResult(sniffed);
  final byExtension = path == null ? null : _formatFromExtension(path);
  return MediaDetectionResult(
    byExtension ?? MediaFormat.unknown,
    byExtensionFallback: true,
  );
}

/// Reads just enough of the file at [path] to classify it (see
/// [kSniffHeaderBytes]), then applies [classifyMediaBytes]. Never throws for
/// an unreadable/missing file — that just yields [MediaFormat.unknown]
/// (unsupported), the same as any other file classification can't identify.
Future<MediaDetectionResult> classifyMediaFile(String path) async {
  final header = await _readHeader(path);
  return classifyMediaBytes(header, path: path);
}

Future<Uint8List> _readHeader(String path) async {
  try {
    final raf = await File(path).open();
    try {
      final length = await raf.length();
      final toRead = length < kSniffHeaderBytes ? length : kSniffHeaderBytes;
      return await raf.read(toRead);
    } finally {
      await raf.close();
    }
  } catch (_) {
    return Uint8List(0);
  }
}

/// Reads the 4-byte ASCII tag at [offset] in [bytes], or `null` if it
/// doesn't fit.
String? _fourCC(Uint8List bytes, int offset) {
  if (offset + 4 > bytes.length) return null;
  return String.fromCharCodes(bytes.sublist(offset, offset + 4));
}

/// ISO base media file format ("ftyp") major brands this app recognizes as
/// a QuickTime `.mov` container specifically, rather than a generic MP4.
const Set<String> _quickTimeBrands = {'qt  '};

MediaFormat? _sniff(Uint8List b) {
  // JPEG: SOI marker FF D8 FF.
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return MediaFormat.jpeg;
  }

  // PNG: the fixed 8-byte signature.
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47 &&
      b[4] == 0x0D &&
      b[5] == 0x0A &&
      b[6] == 0x1A &&
      b[7] == 0x0A) {
    return MediaFormat.png;
  }

  // ISO base media container family: an "ftyp" box at offset 4, its major
  // brand at offset 8. Covers both still-image HEIC/HEIF and MP4/MOV video
  // — same box shape, distinguished by brand.
  if (b.length >= 12 && _fourCC(b, 4) == 'ftyp') {
    final brand = _fourCC(b, 8);
    const heicBrands = {'heic', 'heix', 'hevc', 'hevx', 'mif1'};
    if (brand != null && heicBrands.contains(brand)) return MediaFormat.heic;
    if (brand != null && _quickTimeBrands.contains(brand)) {
      return MediaFormat.quicktime;
    }
    // Any other ftyp brand (isom, iso2, mp41, mp42, M4V , avc1, 3gp*, ...)
    // — not exhaustive of the whole ISOBMFF brand registry, just every
    // brand a phone gallery plausibly hands back, so treat the rest as
    // plain MP4 rather than trying to enumerate every one.
    return MediaFormat.mp4;
  }

  // RIFF container family: 'RIFF' + size(4) + form type at offset 8.
  if (b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46) {
    final form = _fourCC(b, 8);
    if (form == 'WEBP') return MediaFormat.webp;
    if (form == 'AVI ') return MediaFormat.avi;
    return null; // Some other RIFF-based format — inconclusive.
  }

  // Matroska/WebM: EBML magic. WebM is a constrained Matroska profile with
  // the same container signature, so both fall out as one format here —
  // both are handled identically downstream (video).
  if (b.length >= 4 &&
      b[0] == 0x1A &&
      b[1] == 0x45 &&
      b[2] == 0xDF &&
      b[3] == 0xA3) {
    return MediaFormat.matroska;
  }

  // TIFF-structured: 'II'/'MM' + magic 42. Could be a plain TIFF or a DNG
  // (a constrained TIFF subset) — reuse the IFD0 walker in dng_preview.dart
  // rather than a second parser to tell them apart.
  if (b.length >= 4 &&
      ((b[0] == 0x49 && b[1] == 0x49) || (b[0] == 0x4D && b[1] == 0x4D))) {
    return isDngVersionTagPresent(b) ? MediaFormat.dng : MediaFormat.tiff;
  }

  return null; // Inconclusive — caller falls back to extension.
}

MediaFormat? _formatFromExtension(String path) {
  final dot = path.lastIndexOf('.');
  if (dot == -1 || dot == path.length - 1) return null;
  final ext = path.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'jpg' || 'jpeg' => MediaFormat.jpeg,
    'png' => MediaFormat.png,
    'heic' || 'heif' => MediaFormat.heic,
    'webp' => MediaFormat.webp,
    'tiff' || 'tif' => MediaFormat.tiff,
    'dng' => MediaFormat.dng,
    'mp4' || 'm4v' => MediaFormat.mp4,
    'mov' => MediaFormat.quicktime,
    'webm' || 'mkv' => MediaFormat.matroska,
    'avi' => MediaFormat.avi,
    _ => null,
  };
}
