/// Shared "cap the longest edge of an image" idiom, used everywhere a
/// decoded image needs to be bounded to a maximum working resolution before
/// further processing — the RAW import fallback chain
/// (`lib/core/raw_import.dart`) and the photo grading pipeline
/// (`lib/features/photo/photo_processor.dart`) both need it, at more than
/// one call site each, so it lives here rather than being copy-pasted.
library;

import 'package:image/image.dart' as img;

/// Downscales [image] so its longest side is at most [maxDimension],
/// preserving aspect ratio and using average interpolation (a reasonable
/// downsample filter for photo content). Never upscales: returns [image]
/// itself — the same instance, no copy — when it's already within bounds,
/// so callers that may already be working with a capped image (e.g. a
/// RAW-decoded buffer the fallback chain already capped once) don't pay for
/// a wasted resize pass.
img.Image capToMaxDimension(img.Image image, int maxDimension) {
  if (image.width <= maxDimension && image.height <= maxDimension) {
    return image;
  }
  return img.copyResize(
    image,
    width: image.width >= image.height ? maxDimension : null,
    height: image.height > image.width ? maxDimension : null,
    interpolation: img.Interpolation.average,
  );
}
