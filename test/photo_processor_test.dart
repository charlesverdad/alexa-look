import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:alexa_look/features/photo/photo_processor.dart';

/// Builds a tiny, hand-written identity LUT of the given [size], so
/// grading with it should leave pixel colors unchanged (within rounding).
String _identityCube(int size) {
  final buffer = StringBuffer();
  buffer.writeln('TITLE "Identity"');
  buffer.writeln('LUT_3D_SIZE $size');
  final n = size - 1;
  for (var bi = 0; bi < size; bi++) {
    final b = bi / n;
    for (var gi = 0; gi < size; gi++) {
      final g = gi / n;
      for (var ri = 0; ri < size; ri++) {
        final r = ri / n;
        buffer.writeln(
          '${r.toStringAsFixed(6)} ${g.toStringAsFixed(6)} ${b.toStringAsFixed(6)}',
        );
      }
    }
  }
  return buffer.toString();
}

/// Decodes RGBA bytes produced by [preparePhoto]/[gradeCachedPhoto] back
/// into an [img.Image] so pixels can be sampled by position rather than
/// assuming a particular byte layout.
img.Image _decodeRgba(Uint8List rgbaBytes, int width, int height) {
  return img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgbaBytes.buffer,
    order: img.ChannelOrder.rgba,
  );
}

void main() {
  group('preparePhoto', () {
    test('normalizes a 16-bit-per-channel source to 8-bit RGBA', () async {
      // A uint16 source is exactly the case the fix targets: without
      // converting to uint8 first, getBytes() on a 16-bit image returns raw
      // uint16 sample bytes that get misread as 8-bit RGBA and corrupt every
      // pixel. Build one with distinct, easy-to-check colors per pixel.
      final source = img.Image(
        width: 2,
        height: 2,
        format: img.Format.uint16,
        numChannels: 3,
      );
      source.setPixelRgb(0, 0, 65535, 0, 0); // pure red
      source.setPixelRgb(1, 0, 0, 65535, 0); // pure green
      source.setPixelRgb(0, 1, 0, 0, 65535); // pure blue
      source.setPixelRgb(1, 1, 65535, 65535, 65535); // white
      final pngBytes = Uint8List.fromList(img.encodePng(source));

      final prepared = await preparePhoto(
        PhotoPrepareRequest(
          originalBytes: pngBytes,
          cubeText: _identityCube(2),
        ),
      );

      expect(prepared.width, 2);
      expect(prepared.height, 2);
      expect(prepared.rgbaBytes.length, 2 * 2 * 4);

      final decoded = _decodeRgba(prepared.rgbaBytes, 2, 2);
      final red = decoded.getPixel(0, 0);
      expect(red.r, closeTo(255, 1));
      expect(red.g, closeTo(0, 1));
      expect(red.b, closeTo(0, 1));

      final green = decoded.getPixel(1, 0);
      expect(green.r, closeTo(0, 1));
      expect(green.g, closeTo(255, 1));
      expect(green.b, closeTo(0, 1));

      final blue = decoded.getPixel(0, 1);
      expect(blue.r, closeTo(0, 1));
      expect(blue.g, closeTo(0, 1));
      expect(blue.b, closeTo(255, 1));

      final white = decoded.getPixel(1, 1);
      expect(white.r, closeTo(255, 1));
      expect(white.g, closeTo(255, 1));
      expect(white.b, closeTo(255, 1));
    });

    test('bakes EXIF orientation even for images under the resize cap', () async {
      // A 2x1 image, physically red-then-green, tagged as EXIF orientation 6
      // (rotate 90 CW to display correctly) and small enough that the
      // >3000px resize path (which used to be the only place orientation got
      // baked) never runs. Encoded as TIFF, not PNG: this package's PNG
      // codec doesn't round-trip EXIF data at all, so the test uses a format
      // that actually carries the orientation tag through encode/decode.
      final source = img.Image(width: 2, height: 1);
      source.setPixelRgb(0, 0, 255, 0, 0); // red
      source.setPixelRgb(1, 0, 0, 255, 0); // green
      source.exif.imageIfd.orientation = 6;
      final tiffBytes = Uint8List.fromList(img.encodeTiff(source));

      final prepared = await preparePhoto(
        PhotoPrepareRequest(
          originalBytes: tiffBytes,
          cubeText: _identityCube(2),
        ),
      );

      // Orientation 6 rotates 90 degrees clockwise, so the 2x1 source
      // becomes 1x2, with the original left pixel (red) now on top.
      expect(prepared.width, 1);
      expect(prepared.height, 2);
      final decoded = _decodeRgba(prepared.rgbaBytes, 1, 2);
      final top = decoded.getPixel(0, 0);
      expect(top.r, closeTo(255, 1));
      expect(top.g, closeTo(0, 1));
      final bottom = decoded.getPixel(0, 1);
      expect(bottom.r, closeTo(0, 1));
      expect(bottom.g, closeTo(255, 1));
    });
  });

  group('gradeCachedPhoto', () {
    test('reuses a prepared photo to grade at a new intensity', () async {
      final source = img.Image(width: 2, height: 2);
      source.setPixelRgb(0, 0, 200, 50, 50);
      source.setPixelRgb(1, 0, 50, 200, 50);
      source.setPixelRgb(0, 1, 50, 50, 200);
      source.setPixelRgb(1, 1, 10, 10, 10);
      final pngBytes = Uint8List.fromList(img.encodePng(source));

      final prepared = await preparePhoto(
        PhotoPrepareRequest(
          originalBytes: pngBytes,
          cubeText: _identityCube(2),
        ),
      );

      final result = await gradeCachedPhoto(
        PhotoRegradeRequest.from(prepared, 1.0),
      );
      expect(result.width, 2);
      expect(result.height, 2);
      expect(result.gradedBytes, isNotEmpty);

      // Grading again from the same PreparedPhoto at a different intensity
      // must not be affected by the previous call mutating shared state.
      final result2 = await gradeCachedPhoto(
        PhotoRegradeRequest.from(prepared, 0.0),
      );
      expect(result2.width, 2);
      expect(result2.height, 2);

      // With an identity LUT, a 0.0-intensity regrade should still decode to
      // the original source colors.
      final decoded = img.decodePng(result2.gradedBytes)!;
      final p = decoded.getPixel(0, 0);
      expect(p.r, closeTo(200, 1));
      expect(p.g, closeTo(50, 1));
      expect(p.b, closeTo(50, 1));
    });
  });
}
