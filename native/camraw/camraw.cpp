// See camraw.h for the public contract. This file is the only place in the
// app that touches LibRaw's C++ API directly — everything above it (Dart)
// only ever sees the three extern "C" functions declared there.
#include "camraw.h"

#include <cstdlib>
#include <cstring>
#include <new>

#include "libraw/libraw.h"

namespace {

// Releases whatever LibRaw allocated for a dcraw_make_mem_image() result,
// used on every exit path (success or failure) after the call succeeds, so
// we never leak LibRaw's own copy once we've made our own.
void ReleaseProcessedImage(libraw_processed_image_t* img) {
  if (img != nullptr) {
    LibRaw::dcraw_clear_mem(img);
  }
}

}  // namespace

extern "C" int32_t camraw_decode(const uint8_t* data, int32_t len,
                                  int32_t* out_w, int32_t* out_h,
                                  uint8_t** out_rgb) {
  if (data == nullptr || len <= 0 || out_w == nullptr || out_h == nullptr ||
      out_rgb == nullptr) {
    return LIBRAW_UNSPECIFIED_ERROR;
  }

  LibRaw processor;

  // Camera white balance when present in the file, falling back to LibRaw's
  // own auto-WB otherwise (use_camera_wb=1 already implies that fallback).
  processor.imgdata.params.use_camera_wb = 1;
  // 1 == sRGB output color space.
  processor.imgdata.params.output_color = 1;
  // 8 bits per channel: we hand the result straight to package:image as an
  // 8-bit RGB buffer.
  processor.imgdata.params.output_bps = 8;
  // Keep LibRaw's default gentle auto-brightness adjustment (0 == enabled);
  // the app's own grading pipeline expects a reasonably-exposed starting
  // image, same as a decoded JPEG would give it.
  processor.imgdata.params.no_auto_bright = 0;

  int ret = processor.open_buffer(data, static_cast<size_t>(len));
  if (ret != LIBRAW_SUCCESS) {
    return ret;
  }

  ret = processor.unpack();
  if (ret != LIBRAW_SUCCESS) {
    return ret;
  }

  ret = processor.dcraw_process();
  if (ret != LIBRAW_SUCCESS) {
    return ret;
  }

  int mem_err = LIBRAW_SUCCESS;
  libraw_processed_image_t* image = processor.dcraw_make_mem_image(&mem_err);
  if (image == nullptr) {
    return mem_err != LIBRAW_SUCCESS ? mem_err : LIBRAW_UNSPECIFIED_ERROR;
  }
  if (image->type != LIBRAW_IMAGE_BITMAP || image->colors != 3 ||
      image->bits != 8) {
    // Not the 8-bit interleaved RGB bitmap we configured above — treat as
    // an unsupported result rather than misinterpreting its bytes.
    ReleaseProcessedImage(image);
    return LIBRAW_UNSPECIFIED_ERROR;
  }

  const size_t pixel_count =
      static_cast<size_t>(image->width) * static_cast<size_t>(image->height);
  const size_t expected_size = pixel_count * 3;
  if (image->data_size < expected_size) {
    ReleaseProcessedImage(image);
    return LIBRAW_UNSPECIFIED_ERROR;
  }

  uint8_t* rgb = static_cast<uint8_t*>(std::malloc(expected_size));
  if (rgb == nullptr) {
    ReleaseProcessedImage(image);
    return LIBRAW_UNSPECIFIED_ERROR;
  }
  std::memcpy(rgb, image->data, expected_size);

  *out_w = static_cast<int32_t>(image->width);
  *out_h = static_cast<int32_t>(image->height);
  *out_rgb = rgb;

  ReleaseProcessedImage(image);
  return LIBRAW_SUCCESS;
}

extern "C" void camraw_free(uint8_t* buf) {
  std::free(buf);
}

extern "C" const char* camraw_version(void) {
  return LibRaw::version();
}
