import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:alexa_look/core/image_cap.dart';

img.Image _image(int width, int height, {img.Format format = img.Format.uint8}) {
  return img.Image(width: width, height: height, format: format, numChannels: 3);
}

void main() {
  group('capToMaxDimension', () {
    test('returns the same instance, unchanged, when already within bounds', () {
      final image = _image(100, 80);
      final result = capToMaxDimension(image, 200);
      expect(identical(result, image), isTrue);
      expect(result.width, 100);
      expect(result.height, 80);
    });

    test('returns the same instance when exactly at the max on both dimensions', () {
      final image = _image(200, 200);
      final result = capToMaxDimension(image, 200);
      expect(identical(result, image), isTrue);
    });

    test('downscales a landscape image by its width, preserving aspect ratio', () {
      final image = _image(4000, 2000);
      final result = capToMaxDimension(image, 1000);
      expect(result.width, 1000);
      expect(result.height, 500);
    });

    test('downscales a portrait image by its height, preserving aspect ratio', () {
      final image = _image(2000, 4000);
      final result = capToMaxDimension(image, 1000);
      expect(result.height, 1000);
      expect(result.width, 500);
    });

    test('never upscales a small image', () {
      final image = _image(50, 30);
      final result = capToMaxDimension(image, 1000);
      expect(identical(result, image), isTrue);
      expect(result.width, 50);
      expect(result.height, 30);
    });

    test('preserves the image format and channel count through a resize', () {
      final image = _image(4000, 2000, format: img.Format.uint16);
      final result = capToMaxDimension(image, 1000);
      expect(result.format, img.Format.uint16);
      expect(result.numChannels, 3);
    });

    test('a square oversized image is capped on both dimensions equally', () {
      final image = _image(3000, 3000);
      final result = capToMaxDimension(image, 1200);
      expect(result.width, 1200);
      expect(result.height, 1200);
    });
  });
}
