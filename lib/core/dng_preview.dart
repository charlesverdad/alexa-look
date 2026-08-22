/// Pure-Dart extraction of the largest embedded JPEG preview from a DNG (or
/// any TIFF-structured raw) file, by walking its IFD chain.
///
/// This is the last resort in the RAW decode fallback chain (see
/// `lib/core/raw_import.dart`) — it never runs LibRaw or ffmpeg, just reads
/// tags — so it also doubles as the *only* RAW path on platforms with no
/// native decoder (iOS) and no ffmpeg fallback available. It never throws:
/// any malformed or unexpected input simply yields `null`, so callers can
/// treat "no preview found" and "couldn't parse this file" identically.
library;

import 'dart:typed_data';

/// TIFF tag IDs this parser looks at. Not exhaustive of the TIFF/DNG spec —
/// just what's needed to locate embedded JPEG previews.
class _Tag {
  static const int compression = 259;
  static const int photometricInterpretation = 262;
  static const int stripOffsets = 273;
  static const int stripByteCounts = 279;
  static const int jpegIfOffset = 513; // aka "OldJpegInterchangeFormat".
  static const int jpegIfByteCount = 514;
  static const int subIfds = 330;

  /// `DNGVersion` — present in IFD0 if and only if the file conforms to the
  /// DNG spec (a DNG is a constrained subset of TIFF). Used by
  /// [isDngVersionTagPresent] to distinguish a DNG from a plain TIFF.
  static const int dngVersion = 0xC612; // 50706
}

/// TIFF field types, per the TIFF 6.0 spec, and their on-disk byte size —
/// needed to know how many bytes each IFD entry's value/count occupies and
/// whether it fits inline or is stored via an offset.
const Map<int, int> _typeSizes = {
  1: 1, // BYTE
  2: 1, // ASCII
  3: 2, // SHORT
  4: 4, // LONG
  5: 8, // RATIONAL
  6: 1, // SBYTE
  7: 1, // UNDEFINED
  8: 2, // SSHORT
  9: 4, // SLONG
  10: 8, // SRATIONAL
  11: 4, // FLOAT
  12: 8, // DOUBLE
  13: 4, // IFD (same layout as LONG)
};

/// One parsed IFD entry's decoded integer values (LONG/SHORT tags only —
/// all this parser needs), regardless of whether they were stored inline or
/// via an offset.
class _IfdEntry {
  final int tag;
  final int type;
  final List<int> values;
  const _IfdEntry(this.tag, this.type, this.values);

  int get first => values.first;
}

/// Extracts the largest embedded JPEG preview found anywhere in [dngBytes]'s
/// IFD tree (the main IFD chain plus every SubIFD they reference), or
/// `null` if none is found or the file couldn't be parsed as TIFF/DNG.
///
/// Looks for two ways a preview JPEG can be stored:
///  - `JpegIFOffset`/`JpegIFByteCount` (tags 513/514) pointing directly at
///    an embedded JPEG stream — the classic TIFF/EXIF thumbnail mechanism.
///  - A single-strip `StripOffsets`/`StripByteCounts` (273/279) IFD whose
///    `Compression` (259) is JPEG (6 or 7) — how many cameras (including
///    Xiaomi's Pro-mode/UltraRAW DNGs) store a larger preview image.
///
/// When multiple candidates are found (e.g. both a small EXIF thumbnail and
/// a larger preview IFD), the largest by byte length wins.
Uint8List? extractLargestDngPreviewJpeg(Uint8List dngBytes) {
  try {
    return _extract(dngBytes);
  } catch (_) {
    // Any parse error (truncated file, out-of-range offset, etc.) — no
    // preview available, not a crash.
    return null;
  }
}

/// Returns whether [bytes] is TIFF-structured (`II*\0`/`MM\0*`) *and* its
/// IFD0 contains the `DNGVersion` tag (0xC612) — the standard way to tell a
/// DNG apart from a plain TIFF, per the DNG spec (DNGVersion is required and
/// always lives in IFD0, never a SubIFD). Used by
/// `lib/core/media_detector.dart`'s content-based classifier.
///
/// Deliberately much lighter than [extractLargestDngPreviewJpeg]: it only
/// walks IFD0's entry table checking each entry's raw tag id, never
/// resolving any entry's value or type, and never visits SubIFDs or the
/// IFD chain — so it works correctly even when [bytes] is just a leading
/// prefix of a much larger file, as long as that prefix reaches past IFD0's
/// entry table (comfortably true for any real phone DNG within a small
/// sniffed header). Never throws: any malformed/truncated input, or a file
/// that isn't TIFF-structured at all, simply yields `false`.
bool isDngVersionTagPresent(Uint8List bytes) {
  try {
    if (bytes.length < 8) return false;
    final data = ByteData.sublistView(bytes);

    final Endian endian;
    if (bytes[0] == 0x49 && bytes[1] == 0x49) {
      endian = Endian.little;
    } else if (bytes[0] == 0x4D && bytes[1] == 0x4D) {
      endian = Endian.big;
    } else {
      return false;
    }
    if (data.getUint16(2, endian) != 42) return false;

    final ifd0Offset = data.getUint32(4, endian);
    if (ifd0Offset <= 0 || ifd0Offset + 2 > bytes.length) return false;

    final count = data.getUint16(ifd0Offset, endian);
    final entriesStart = ifd0Offset + 2;
    final entriesEnd = entriesStart + count * 12;
    // If the available bytes don't reach the end of IFD0's entry table,
    // there isn't enough here to be sure — report "not a DNG" rather than
    // risk reading past the buffer. Real DNGs' IFD0 entry tables are a few
    // hundred bytes at most, well within any reasonable sniffed prefix.
    if (entriesEnd > bytes.length) return false;

    for (var i = 0; i < count; i++) {
      final entryOffset = entriesStart + i * 12;
      if (data.getUint16(entryOffset, endian) == _Tag.dngVersion) return true;
    }
    return false;
  } catch (_) {
    return false;
  }
}

Uint8List? _extract(Uint8List bytes) {
  if (bytes.length < 8) return null;
  final data = ByteData.sublistView(bytes);

  final Endian endian;
  if (bytes[0] == 0x49 && bytes[1] == 0x49) {
    endian = Endian.little; // 'II'
  } else if (bytes[0] == 0x4D && bytes[1] == 0x4D) {
    endian = Endian.big; // 'MM'
  } else {
    return null; // Not a TIFF-structured file.
  }

  final magic = data.getUint16(2, endian);
  if (magic != 42) return null;

  final firstIfdOffset = data.getUint32(4, endian);
  if (firstIfdOffset == 0) return null;

  Uint8List? best;
  final visited = <int>{};
  final toVisit = <int>[firstIfdOffset];

  while (toVisit.isNotEmpty) {
    final offset = toVisit.removeLast();
    if (offset <= 0 || offset >= bytes.length || !visited.add(offset)) {
      continue;
    }

    final result = _readIfd(data, bytes, offset, endian);
    if (result == null) continue;
    final entries = result.entries;

    // Queue this IFD's chained "next IFD" (IFD0 -> IFD1 -> ... in the main
    // chain) and any SubIFDs it references, so every reachable IFD is
    // eventually visited regardless of how deep the tree goes.
    if (result.nextIfdOffset != 0) {
      toVisit.add(result.nextIfdOffset);
    }
    final subIfds = entries[_Tag.subIfds];
    if (subIfds != null) {
      toVisit.addAll(subIfds.values);
    }

    final candidate = _previewFromIfd(entries, bytes);
    final current = best;
    if (candidate != null && (current == null || candidate.length > current.length)) {
      best = candidate;
    }
  }

  return best;
}

class _IfdReadResult {
  final Map<int, _IfdEntry> entries;
  final int nextIfdOffset;
  const _IfdReadResult(this.entries, this.nextIfdOffset);
}

/// Reads one IFD at [offset]: its entry count, that many 12-byte entries,
/// and the trailing 4-byte "offset of next IFD" (0 if none). Returns `null`
/// if the IFD's header/entries don't fit within [bytes].
_IfdReadResult? _readIfd(
    ByteData data, Uint8List bytes, int offset, Endian endian) {
  if (offset + 2 > bytes.length) return null;
  final count = data.getUint16(offset, endian);
  final entriesStart = offset + 2;
  final entriesEnd = entriesStart + count * 12;
  if (entriesEnd + 4 > bytes.length) return null;

  final entries = <int, _IfdEntry>{};
  for (var i = 0; i < count; i++) {
    final entryOffset = entriesStart + i * 12;
    final tag = data.getUint16(entryOffset, endian);
    final type = data.getUint16(entryOffset + 2, endian);
    final valueCount = data.getUint32(entryOffset + 4, endian);
    final valueFieldOffset = entryOffset + 8;

    final typeSize = _typeSizes[type];
    // Unknown type or absurd count (guards against a corrupt count causing
    // a huge allocation/scan below) — skip this entry, keep parsing others.
    if (typeSize == null || valueCount < 0 || valueCount > 0x100000) {
      continue;
    }
    // This parser only ever needs integer-valued tags (offsets, byte
    // counts, dimensions, compression, subfile type) — all SHORT or LONG.
    if (type != 3 && type != 4 && type != 13) continue;

    final totalSize = typeSize * valueCount;
    final int dataStart;
    if (totalSize <= 4) {
      dataStart = valueFieldOffset;
    } else {
      if (valueFieldOffset + 4 > bytes.length) continue;
      dataStart = data.getUint32(valueFieldOffset, endian);
    }
    if (dataStart < 0 || dataStart + totalSize > bytes.length) continue;

    final values = <int>[];
    for (var v = 0; v < valueCount; v++) {
      final pos = dataStart + v * typeSize;
      values.add(type == 3 ? data.getUint16(pos, endian) : data.getUint32(pos, endian));
    }
    entries[tag] = _IfdEntry(tag, type, values);
  }

  final nextIfdOffset = data.getUint32(entriesEnd, endian);
  return _IfdReadResult(entries, nextIfdOffset);
}

/// Pulls a candidate preview JPEG's bytes out of one already-parsed IFD's
/// tags, if it has one, validating it actually starts with a JPEG SOI
/// marker (0xFFD8) before returning it.
Uint8List? _previewFromIfd(Map<int, _IfdEntry> entries, Uint8List bytes) {
  final jpegOffset = entries[_Tag.jpegIfOffset];
  final jpegLength = entries[_Tag.jpegIfByteCount];
  if (jpegOffset != null && jpegLength != null) {
    final candidate =
        _sliceIfValidJpeg(bytes, jpegOffset.first, jpegLength.first);
    if (candidate != null) return candidate;
  }

  final compression = entries[_Tag.compression]?.first;
  final isJpegCompression = compression == 6 || compression == 7;
  // DNG reuses Compression=7 both for baseline-JPEG RGB/YCbCr previews and
  // for lossless-JPEG-encoded raw CFA tiles — both start with a JPEG SOI
  // marker, so the marker check alone can't tell them apart. Requiring an
  // RGB/YCbCr PhotometricInterpretation excludes the raw-CFA case (which
  // has none of those, typically CFA=32803 or none at all).
  final photometric = entries[_Tag.photometricInterpretation]?.first;
  final isViewableColor = photometric == 2 /* RGB */ || photometric == 6 /* YCbCr */;
  final stripOffsets = entries[_Tag.stripOffsets];
  final stripByteCounts = entries[_Tag.stripByteCounts];
  if (isJpegCompression &&
      isViewableColor &&
      stripOffsets != null &&
      stripByteCounts != null &&
      stripOffsets.values.length == 1 &&
      stripByteCounts.values.length == 1) {
    // A single-strip JPEG-compressed IFD: the whole strip is one embedded
    // JPEG stream. (Multi-strip JPEG-compressed IFDs — tiled previews —
    // aren't a simple byte-concatenation of a valid JPEG, so are skipped
    // rather than risk handing back corrupt data.)
    final candidate = _sliceIfValidJpeg(
        bytes, stripOffsets.values.first, stripByteCounts.values.first);
    if (candidate != null) return candidate;
  }

  return null;
}

Uint8List? _sliceIfValidJpeg(Uint8List bytes, int offset, int length) {
  if (length < 4 || offset < 0 || offset + length > bytes.length) {
    return null;
  }
  if (bytes[offset] != 0xFF || bytes[offset + 1] != 0xD8) {
    return null; // Not a JPEG SOI marker.
  }
  return Uint8List.sublistView(bytes, offset, offset + length);
}
