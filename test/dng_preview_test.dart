// Tests for the pure-Dart embedded-JPEG-preview extractor
// (lib/core/dng_preview.dart), against small hand-crafted TIFF/DNG-shaped
// byte structures — real DNGs are megabytes, so these are minimal synthetic
// IFDs covering just the tag combinations the parser looks at.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:alexa_look/core/dng_preview.dart';

// --- TIFF tag IDs used by the fixtures below --------------------------------
const int _tagCompression = 259;
const int _tagPhotometric = 262;
const int _tagStripOffsets = 273;
const int _tagStripByteCounts = 279;
const int _tagJpegIfOffset = 513;
const int _tagJpegIfByteCount = 514;
const int _tagSubIfds = 330;

const int _typeShort = 3;
const int _typeLong = 4;

/// A single not-yet-laid-out IFD entry. [value] is either a plain `int`
/// (written as-is) or a [_JpegRef] placeholder resolved once the
/// referenced JPEG blob's file offset/length are known.
class _Entry {
  final int tag;
  final int type;
  final Object value; // int, or _JpegOffset/_JpegLength
  const _Entry(this.tag, this.type, this.value);
}

/// Placeholder written into an [_Entry]'s value slot, resolved during
/// layout to the byte offset of jpeg blob #[index] within the final file.
class _JpegOffset {
  final int index;
  const _JpegOffset(this.index);
}

/// Same as [_JpegOffset] but resolves to that blob's byte length.
class _JpegLength {
  final int index;
  const _JpegLength(this.index);
}

/// A minimal valid JPEG byte sequence (just SOI...EOI, no real image data —
/// the parser only checks the leading SOI marker and byte length, it never
/// actually decodes these in these tests).
Uint8List _fakeJpeg(int payloadLen) {
  final bytes = Uint8List(4 + payloadLen);
  bytes[0] = 0xFF;
  bytes[1] = 0xD8; // SOI
  for (var i = 0; i < payloadLen; i++) {
    bytes[2 + i] = 0x00;
  }
  bytes[bytes.length - 2] = 0xFF;
  bytes[bytes.length - 1] = 0xD9; // EOI
  return bytes;
}

/// Builds a little-endian TIFF-structured byte buffer: a header, then each
/// of [ifds] laid out back-to-back (chained via "next IFD" in list order,
/// terminating with 0), then each of [jpegBlobs] laid out back-to-back
/// after all the IFDs — with any [_JpegOffset]/[_JpegLength] placeholders
/// in the entries resolved against those blobs' final positions.
///
/// Every entry here is a single SHORT or LONG value (fits inline in a
/// TIFF IFD entry's 4-byte value field), so no separate "value data" area
/// is needed — this keeps the builder simple while still covering every
/// tag combination the parser reads.
Uint8List _buildTiff({
  required List<List<_Entry>> ifds,
  List<Uint8List> jpegBlobs = const [],
}) {
  const headerSize = 8;
  final ifdSizes = ifds.map((e) => 2 + e.length * 12 + 4).toList();
  final ifdOffsets = <int>[];
  var cursor = headerSize;
  for (final size in ifdSizes) {
    ifdOffsets.add(cursor);
    cursor += size;
  }

  final jpegOffsets = <int>[];
  for (final blob in jpegBlobs) {
    jpegOffsets.add(cursor);
    cursor += blob.length;
  }

  final total = cursor;
  final out = ByteData(total);
  final bytes = Uint8List.view(out.buffer);

  bytes[0] = 0x49;
  bytes[1] = 0x49; // 'II' little-endian
  out.setUint16(2, 42, Endian.little);
  out.setUint32(4, ifdOffsets.first, Endian.little);

  for (var i = 0; i < ifds.length; i++) {
    final entries = ifds[i];
    var offset = ifdOffsets[i];
    out.setUint16(offset, entries.length, Endian.little);
    offset += 2;
    for (final entry in entries) {
      out.setUint16(offset, entry.tag, Endian.little);
      out.setUint16(offset + 2, entry.type, Endian.little);
      out.setUint32(offset + 4, 1, Endian.little); // count: always 1 here.
      final resolved = switch (entry.value) {
        _JpegOffset(:final index) => jpegOffsets[index],
        _JpegLength(:final index) => jpegBlobs[index].length,
        final int v => v,
        _ => throw StateError('unreachable'),
      };
      out.setUint32(offset + 8, resolved, Endian.little);
      offset += 12;
    }
    final nextIfdOffset = i + 1 < ifds.length ? ifdOffsets[i + 1] : 0;
    out.setUint32(offset, nextIfdOffset, Endian.little);
  }

  for (var i = 0; i < jpegBlobs.length; i++) {
    bytes.setRange(
        jpegOffsets[i], jpegOffsets[i] + jpegBlobs[i].length, jpegBlobs[i]);
  }

  return bytes;
}

void main() {
  group('extractLargestDngPreviewJpeg', () {
    test('finds a preview via JpegIFOffset/JpegIFByteCount', () {
      final jpeg = _fakeJpeg(20);
      final bytes = _buildTiff(ifds: [
        [
          const _Entry(_tagCompression, _typeShort, 6),
          const _Entry(_tagJpegIfOffset, _typeLong, _JpegOffset(0)),
          const _Entry(_tagJpegIfByteCount, _typeLong, _JpegLength(0)),
        ],
      ], jpegBlobs: [
        jpeg,
      ]);

      final result = extractLargestDngPreviewJpeg(bytes);
      expect(result, isNotNull);
      expect(result, equals(jpeg));
    });

    test('finds a preview via a single-strip JPEG-compressed IFD', () {
      final jpeg = _fakeJpeg(16);
      final bytes = _buildTiff(ifds: [
        [
          const _Entry(_tagCompression, _typeShort, 7),
          const _Entry(_tagPhotometric, _typeShort, 6), // YCbCr
          const _Entry(_tagStripOffsets, _typeLong, _JpegOffset(0)),
          const _Entry(_tagStripByteCounts, _typeLong, _JpegLength(0)),
        ],
      ], jpegBlobs: [
        jpeg,
      ]);

      final result = extractLargestDngPreviewJpeg(bytes);
      expect(result, equals(jpeg));
    });

    test('ignores a single-strip JPEG-compressed IFD with no viewable '
        'PhotometricInterpretation (raw CFA data, not an RGB/YCbCr preview)', () {
      final rawLikeStrip = _fakeJpeg(16); // starts with FFD8 but isn't a preview.
      final bytes = _buildTiff(ifds: [
        [
          const _Entry(_tagCompression, _typeShort, 7),
          // No PhotometricInterpretation tag at all — as a raw CFA IFD
          // commonly has.
          const _Entry(_tagStripOffsets, _typeLong, _JpegOffset(0)),
          const _Entry(_tagStripByteCounts, _typeLong, _JpegLength(0)),
        ],
      ], jpegBlobs: [
        rawLikeStrip,
      ]);

      expect(extractLargestDngPreviewJpeg(bytes), isNull);
    });

    test('chooses the largest of multiple previews across chained IFDs', () {
      final small = _fakeJpeg(8);
      final large = _fakeJpeg(200);
      final bytes = _buildTiff(ifds: [
        [
          const _Entry(_tagCompression, _typeShort, 6),
          const _Entry(_tagJpegIfOffset, _typeLong, _JpegOffset(0)),
          const _Entry(_tagJpegIfByteCount, _typeLong, _JpegLength(0)),
        ],
        [
          const _Entry(_tagCompression, _typeShort, 7),
          const _Entry(_tagPhotometric, _typeShort, 2), // RGB
          const _Entry(_tagStripOffsets, _typeLong, _JpegOffset(1)),
          const _Entry(_tagStripByteCounts, _typeLong, _JpegLength(1)),
        ],
      ], jpegBlobs: [
        small,
        large,
      ]);

      final result = extractLargestDngPreviewJpeg(bytes);
      expect(result, equals(large));
      expect(result!.length, greaterThan(small.length));
    });

    test('follows SubIFDs to find a preview nested there', () {
      final jpeg = _fakeJpeg(30);
      // IFD0 (the "main" IFD, no preview of its own) points via SubIFDs
      // (tag 330) at IFD1, which holds the actual preview.
      final bytes = _buildTiff(ifds: [
        [
          const _Entry(_tagSubIfds, _typeLong, 0), // patched to IFD1's offset below.
        ],
        [
          const _Entry(_tagCompression, _typeShort, 6),
          const _Entry(_tagJpegIfOffset, _typeLong, _JpegOffset(0)),
          const _Entry(_tagJpegIfByteCount, _typeLong, _JpegLength(0)),
        ],
      ], jpegBlobs: [
        jpeg,
      ]);

      // The builder above doesn't know how to point SubIFDs at another
      // IFD's offset (only at jpeg blobs), so patch it by hand: IFD1
      // starts right after IFD0's fixed-size header (2 + 1*12 + 4 = 18
      // bytes) at file offset 8.
      final patched = Uint8List.fromList(bytes);
      final ifd0EntryValueOffset = 8 + 2 + 8; // header + count + (tag,type,count)
      final ifd1Offset = 8 + 18;
      ByteData.view(patched.buffer)
          .setUint32(ifd0EntryValueOffset, ifd1Offset, Endian.little);

      final result = extractLargestDngPreviewJpeg(patched);
      expect(result, equals(jpeg));
    });

    test('returns null when there is no preview at all', () {
      final bytes = _buildTiff(ifds: [
        [
          const _Entry(_tagCompression, _typeShort, 1), // uncompressed raw.
        ],
      ]);
      expect(extractLargestDngPreviewJpeg(bytes), isNull);
    });

    test('returns null, not a crash, for malformed/truncated input', () {
      expect(extractLargestDngPreviewJpeg(Uint8List(0)), isNull);
      expect(extractLargestDngPreviewJpeg(Uint8List(4)), isNull);
      // Valid header but an IFD offset pointing past the end of the file.
      final bogus = Uint8List(8);
      final bd = ByteData.view(bogus.buffer);
      bd.setUint8(0, 0x49);
      bd.setUint8(1, 0x49);
      bd.setUint16(2, 42, Endian.little);
      bd.setUint32(4, 1000, Endian.little);
      expect(extractLargestDngPreviewJpeg(bogus), isNull);

      // Wrong magic / not TIFF at all.
      expect(extractLargestDngPreviewJpeg(Uint8List.fromList(
          List<int>.filled(16, 0xAB))), isNull);

      // Big-endian header ('MM') with a truncated IFD entry table.
      final beTruncated = Uint8List(12);
      final beBd = ByteData.view(beTruncated.buffer);
      beBd.setUint8(0, 0x4D);
      beBd.setUint8(1, 0x4D);
      beBd.setUint16(2, 42, Endian.big);
      beBd.setUint32(4, 8, Endian.big);
      beBd.setUint16(8, 5, Endian.big); // claims 5 entries, way too few bytes.
      expect(extractLargestDngPreviewJpeg(beTruncated), isNull);
    });

    test('handles a big-endian ("MM") file the same as little-endian', () {
      final jpeg = _fakeJpeg(12);
      // Build directly in big-endian since _buildTiff is little-endian-only.
      const headerSize = 8;
      const entryCount = 3;
      const ifdSize = 2 + entryCount * 12 + 4;
      final jpegOffset = headerSize + ifdSize;
      final total = jpegOffset + jpeg.length;
      final out = ByteData(total);
      out.setUint8(0, 0x4D);
      out.setUint8(1, 0x4D);
      out.setUint16(2, 42, Endian.big);
      out.setUint32(4, headerSize, Endian.big);

      var offset = headerSize;
      out.setUint16(offset, entryCount, Endian.big);
      offset += 2;
      void writeEntry(int tag, int type, int value) {
        out.setUint16(offset, tag, Endian.big);
        out.setUint16(offset + 2, type, Endian.big);
        out.setUint32(offset + 4, 1, Endian.big);
        out.setUint32(offset + 8, value, Endian.big);
        offset += 12;
      }

      writeEntry(_tagCompression, _typeShort, 6);
      writeEntry(_tagJpegIfOffset, _typeLong, jpegOffset);
      writeEntry(_tagJpegIfByteCount, _typeLong, jpeg.length);
      out.setUint32(offset, 0, Endian.big); // next IFD.

      final bytes = Uint8List.view(out.buffer);
      bytes.setRange(jpegOffset, jpegOffset + jpeg.length, jpeg);

      expect(extractLargestDngPreviewJpeg(bytes), equals(jpeg));
    });
  });
}
