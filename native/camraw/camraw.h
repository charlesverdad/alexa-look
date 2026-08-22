// camraw: a tiny extern "C" wrapper around LibRaw, built into libcamraw.so
// and loaded from Dart via dart:ffi (see lib/core/raw_decoder.dart).
//
// Kept deliberately minimal: three functions, no LibRaw types leak across
// the boundary. Every returned buffer is malloc'd by LibRaw/this wrapper and
// must be released with camraw_free (not free() directly, so the allocator
// stays whatever LibRaw/this library actually used).
#ifndef CAMRAW_H_
#define CAMRAW_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Decodes a DNG (or other LibRaw-supported raw) file already fully read
// into memory at [data]/[len] into an 8-bit interleaved RGB image.
//
// On success (return value 0), *out_w and *out_h are set to the decoded
// image's dimensions and *out_rgb points at a freshly malloc'd buffer of
// exactly (*out_w) * (*out_h) * 3 bytes, ownership transferred to the
// caller — release it with camraw_free() once done. On failure, a nonzero
// LibRaw error code is returned (see LibRaw's LIBRAW_* enum /
// LibRaw::strerror) and *out_rgb is left untouched (not written).
//
// NOT thread-safe: this library is built with LIBRAW_NOTHREADS, so
// camraw_decode must never run concurrently from multiple threads. Callers
// must serialize decodes (the Dart side runs one Isolate.run decode at a
// time).
int32_t camraw_decode(const uint8_t* data, int32_t len, int32_t* out_w,
                       int32_t* out_h, uint8_t** out_rgb);

// Frees a buffer previously returned via *out_rgb from camraw_decode.
// Safe to call with NULL (no-op).
void camraw_free(uint8_t* buf);

// Returns LibRaw's own version string (e.g. "0.21.5"), for diagnostics /
// the in-app licenses note. The returned pointer is static and must not be
// freed.
const char* camraw_version(void);

#ifdef __cplusplus
}
#endif

#endif  // CAMRAW_H_
