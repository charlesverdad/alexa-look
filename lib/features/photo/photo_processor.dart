import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../core/cube_lut.dart';

/// Input to [gradePhoto], bundled into one object so it can be sent across
/// the isolate boundary in a single message.
class PhotoGradeRequest {
  final Uint8List originalBytes;
  final String cubeText;
  final double intensity;

  const PhotoGradeRequest({
    required this.originalBytes,
    required this.cubeText,
    required this.intensity,
  });
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

/// Decodes [request.originalBytes], applies the Alexa Look LUT blended at
/// [PhotoGradeRequest.intensity], and returns PNG-encoded bytes.
///
/// Runs the whole decode/grade/encode pipeline in a background isolate via
/// [Isolate.run] so the UI thread never blocks on it.
Future<PhotoGradeResult> gradePhoto(PhotoGradeRequest request) {
  return Isolate.run(() => _gradePhotoSync(request));
}

PhotoGradeResult _gradePhotoSync(PhotoGradeRequest request) {
  final decoded = img.decodeImage(request.originalBytes);
  if (decoded == null) {
    throw const FormatException('Could not decode the selected image.');
  }

  // Cap the working resolution to keep processing time and memory bounded
  // on typical phone photos while still producing a shareable result.
  const maxDimension = 3000;
  var image = decoded;
  if (image.width > maxDimension || image.height > maxDimension) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? maxDimension : null,
      height: image.height > image.width ? maxDimension : null,
      interpolation: img.Interpolation.average,
    );
  }

  final lut = CubeLut.parse(request.cubeText);
  final rgbaBytes = image.getBytes(order: img.ChannelOrder.rgba);
  lut.applyToRgbBytes(
    rgbaBytes,
    channelsPerPixel: 4,
    intensity: request.intensity,
  );
  final graded = img.Image.fromBytes(
    width: image.width,
    height: image.height,
    bytes: rgbaBytes.buffer,
    order: img.ChannelOrder.rgba,
  );

  final pngBytes = Uint8List.fromList(img.encodePng(graded));
  return PhotoGradeResult(
    gradedBytes: pngBytes,
    width: graded.width,
    height: graded.height,
  );
}
