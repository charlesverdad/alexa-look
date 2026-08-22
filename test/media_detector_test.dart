// Tests for the content-based media classifier (lib/core/media_detector.dart)
// against small synthetic byte fixtures for every format branch, DNG-vs-TIFF
// discrimination, and the extension fallback for inconclusive content.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:alexa_look/core/media_detector.dart';

/// Pads/truncates isn't needed — these fixtures are just the leading bytes
/// classifyMediaBytes actually looks at; only what's asserted-on has real
/// content, the rest is zero-filled.
Uint8List _bytes(List<int> head, {int totalLength = 32}) {
  final out = Uint8List(totalLength < head.length ? head.length : totalLength);
  out.setRange(0, head.length, head);
  return out;
}

/// Builds a minimal little-endian TIFF-structured buffer: an 8-byte header
/// pointing at IFD0 immediately after it, followed by IFD0's entry table
/// (one 12-byte entry per tag in [tags], each a dummy SHORT value) and a
/// trailing 0 "next IFD" offset. Entry values are never decoded by
/// [isDngVersionTagPresent]/the classifier's DNG check, so they're left as
/// zero.
Uint8List _buildTiff(List<int> tags) {
  const headerSize = 8;
  final ifdOffset = headerSize;
  final entryCount = tags.length;
  final totalSize = headerSize + 2 + entryCount * 12 + 4;
  final bytes = Uint8List(totalSize);
  final data = ByteData.sublistView(bytes);

  bytes[0] = 0x49; // 'I'
  bytes[1] = 0x49; // 'I'
  data.setUint16(2, 42, Endian.little);
  data.setUint32(4, ifdOffset, Endian.little);

  data.setUint16(ifdOffset, entryCount, Endian.little);
  var entryOffset = ifdOffset + 2;
  for (final tag in tags) {
    data.setUint16(entryOffset, tag, Endian.little); // tag
    data.setUint16(entryOffset + 2, 3, Endian.little); // type: SHORT
    data.setUint32(entryOffset + 4, 1, Endian.little); // count: 1
    data.setUint16(entryOffset + 8, 0, Endian.little); // dummy value
    entryOffset += 12;
  }
  // Trailing "next IFD offset" = 0 (terminates the chain).
  data.setUint32(entryOffset, 0, Endian.little);

  return bytes;
}

void main() {
  group('classifyMediaBytes — content sniffing per format', () {
    test('JPEG: SOI marker', () {
      final result = classifyMediaBytes(_bytes([0xFF, 0xD8, 0xFF, 0xE0]));
      expect(result.format, MediaFormat.jpeg);
      expect(result.category, MediaCategory.photo);
      expect(result.byExtensionFallback, isFalse);
    });

    test('PNG: 8-byte signature', () {
      final result = classifyMediaBytes(
        _bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
      );
      expect(result.format, MediaFormat.png);
      expect(result.category, MediaCategory.photo);
    });

    test('HEIC/HEIF: ftyp brand heic', () {
      final bytes = _bytes(
        [0, 0, 0, 0x18, ..._ascii('ftyp'), ..._ascii('heic')],
      );
      expect(classifyMediaBytes(bytes).format, MediaFormat.heic);
    });

    test('HEIC/HEIF: ftyp brand mif1 (a common HEIF compatible brand)', () {
      final bytes = _bytes(
        [0, 0, 0, 0x18, ..._ascii('ftyp'), ..._ascii('mif1')],
      );
      final result = classifyMediaBytes(bytes);
      expect(result.format, MediaFormat.heic);
      expect(result.category, MediaCategory.photo);
    });

    test('WebP: RIFF....WEBP', () {
      final bytes = _bytes(
        [..._ascii('RIFF'), 0, 0, 0, 0, ..._ascii('WEBP')],
      );
      expect(classifyMediaBytes(bytes).format, MediaFormat.webp);
    });

    test('TIFF: plain TIFF (no DNGVersion tag) little-endian', () {
      final bytes = _buildTiff([256, 257]); // ImageWidth, ImageLength — not DNGVersion.
      final result = classifyMediaBytes(bytes);
      expect(result.format, MediaFormat.tiff);
      expect(result.category, MediaCategory.photo);
    });

    test('DNG: TIFF-structured with DNGVersion tag (0xC612) in IFD0', () {
      final bytes = _buildTiff([256, 0xC612, 257]);
      final result = classifyMediaBytes(bytes);
      expect(result.format, MediaFormat.dng);
      expect(result.category, MediaCategory.raw);
    });

    test('MP4: ftyp brand isom', () {
      final bytes = _bytes(
        [0, 0, 0, 0x20, ..._ascii('ftyp'), ..._ascii('isom')],
      );
      final result = classifyMediaBytes(bytes);
      expect(result.format, MediaFormat.mp4);
      expect(result.category, MediaCategory.video);
    });

    test('MOV: ftyp brand "qt  " (QuickTime)', () {
      final bytes = _bytes(
        [0, 0, 0, 0x14, ..._ascii('ftyp'), ..._ascii('qt  ')],
      );
      final result = classifyMediaBytes(bytes);
      expect(result.format, MediaFormat.quicktime);
      expect(result.category, MediaCategory.video);
    });

    test('Matroska/WebM: EBML magic', () {
      final bytes = _bytes([0x1A, 0x45, 0xDF, 0xA3, 0x93]);
      final result = classifyMediaBytes(bytes);
      expect(result.format, MediaFormat.matroska);
      expect(result.category, MediaCategory.video);
    });

    test('AVI: RIFF....AVI ', () {
      final bytes = _bytes(
        [..._ascii('RIFF'), 0, 0, 0, 0, ..._ascii('AVI ')],
      );
      final result = classifyMediaBytes(bytes);
      expect(result.format, MediaFormat.avi);
      expect(result.category, MediaCategory.video);
    });

    test('big-endian ("MM") TIFF is recognized the same as little-endian', () {
      // Build a big-endian TIFF by hand: header only, no IFD0 entries (still
      // enough to be recognized as *a* TIFF and, since it can't find
      // DNGVersion, classified as plain TIFF rather than DNG).
      final bytes = Uint8List(10);
      final data = ByteData.sublistView(bytes);
      bytes[0] = 0x4D;
      bytes[1] = 0x4D; // 'MM'
      data.setUint16(2, 42, Endian.big);
      data.setUint32(4, 8, Endian.big);
      data.setUint16(8, 0, Endian.big); // IFD0 with 0 entries.
      final result = classifyMediaBytes(bytes);
      expect(result.format, MediaFormat.tiff);
    });
  });

  group('classifyMediaBytes — extension fallback when content is inconclusive', () {
    test('unrecognizable content falls back to the path\'s extension', () {
      final junk = _bytes([0x00, 0x11, 0x22, 0x33]);
      final result = classifyMediaBytes(junk, path: '/tmp/photo.PNG');
      expect(result.format, MediaFormat.png);
      expect(result.byExtensionFallback, isTrue);
    });

    test('extension fallback is case-insensitive', () {
      final junk = _bytes([0x00, 0x11]);
      expect(classifyMediaBytes(junk, path: 'clip.MOV').format, MediaFormat.quicktime);
      expect(classifyMediaBytes(junk, path: 'clip.mkv').format, MediaFormat.matroska);
      expect(classifyMediaBytes(junk, path: 'raw.DNG').format, MediaFormat.dng);
    });

    test('inconclusive content with no path at all yields unknown/unsupported', () {
      final junk = _bytes([0x00, 0x11, 0x22, 0x33]);
      final result = classifyMediaBytes(junk);
      expect(result.format, MediaFormat.unknown);
      expect(result.category, MediaCategory.unsupported);
      expect(result.byExtensionFallback, isTrue);
    });

    test('inconclusive content with an unrecognized extension yields unknown/unsupported', () {
      final junk = _bytes([0x00, 0x11, 0x22, 0x33]);
      final result = classifyMediaBytes(junk, path: '/tmp/notes.txt');
      expect(result.format, MediaFormat.unknown);
      expect(result.category, MediaCategory.unsupported);
    });

    test('recognized content wins over a misleading extension (content, not extension, rules)', () {
      final jpegBytes = _bytes([0xFF, 0xD8, 0xFF, 0xE0]);
      final result = classifyMediaBytes(jpegBytes, path: '/tmp/not_actually.mp4');
      expect(result.format, MediaFormat.jpeg);
      expect(result.byExtensionFallback, isFalse);
    });

    test('an empty file with no path is unknown', () {
      final result = classifyMediaBytes(Uint8List(0));
      expect(result.format, MediaFormat.unknown);
    });
  });
}

List<int> _ascii(String s) => s.codeUnits;
