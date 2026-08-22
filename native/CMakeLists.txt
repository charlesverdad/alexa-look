# Builds libcamraw.so: a vendored, trimmed LibRaw (native/libraw/, see
# native/libraw/VENDORING.md) plus the thin extern "C" wrapper
# (native/camraw/) that lib/core/raw_decoder.dart loads via dart:ffi.
#
# Only ever built by the Android Gradle Plugin's externalNativeBuild
# (android/app/build.gradle.kts points at this file), which supplies the
# NDK's CMake + clang toolchain — there is no host build of this target.
cmake_minimum_required(VERSION 3.18)
project(camraw CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# LibRaw needs both: exceptions to report internal errors up through its own
# C++ API, RTTI for a couple of dynamic_casts in its metadata parsers.
# These are already the NDK's defaults for c++_static/c++_shared, but set
# them explicitly so a toolchain default change can't silently break this.
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fexceptions -frtti")

set(LIBRAW_DIR "${CMAKE_CURRENT_SOURCE_DIR}/libraw")

add_library(camraw SHARED
  camraw/camraw.cpp

  ${LIBRAW_DIR}/src/decoders/canon_600.cpp
  ${LIBRAW_DIR}/src/decoders/crx.cpp
  ${LIBRAW_DIR}/src/decoders/decoders_dcraw.cpp
  ${LIBRAW_DIR}/src/decoders/decoders_libraw.cpp
  ${LIBRAW_DIR}/src/decoders/decoders_libraw_dcrdefs.cpp
  ${LIBRAW_DIR}/src/decoders/dng.cpp
  ${LIBRAW_DIR}/src/decoders/fp_dng.cpp
  ${LIBRAW_DIR}/src/decoders/fuji_compressed.cpp
  ${LIBRAW_DIR}/src/decoders/generic.cpp
  ${LIBRAW_DIR}/src/decoders/kodak_decoders.cpp
  ${LIBRAW_DIR}/src/decoders/load_mfbacks.cpp
  ${LIBRAW_DIR}/src/decoders/smal.cpp
  ${LIBRAW_DIR}/src/decoders/unpack.cpp
  ${LIBRAW_DIR}/src/decoders/unpack_thumb.cpp
  ${LIBRAW_DIR}/src/demosaic/aahd_demosaic.cpp
  ${LIBRAW_DIR}/src/demosaic/ahd_demosaic.cpp
  ${LIBRAW_DIR}/src/demosaic/dcb_demosaic.cpp
  ${LIBRAW_DIR}/src/demosaic/dht_demosaic.cpp
  ${LIBRAW_DIR}/src/demosaic/misc_demosaic.cpp
  ${LIBRAW_DIR}/src/demosaic/xtrans_demosaic.cpp
  ${LIBRAW_DIR}/src/integration/dngsdk_glue.cpp
  ${LIBRAW_DIR}/src/integration/rawspeed_glue.cpp
  ${LIBRAW_DIR}/src/libraw_c_api.cpp
  ${LIBRAW_DIR}/src/libraw_datastream.cpp
  ${LIBRAW_DIR}/src/metadata/adobepano.cpp
  ${LIBRAW_DIR}/src/metadata/canon.cpp
  ${LIBRAW_DIR}/src/metadata/ciff.cpp
  ${LIBRAW_DIR}/src/metadata/cr3_parser.cpp
  ${LIBRAW_DIR}/src/metadata/epson.cpp
  ${LIBRAW_DIR}/src/metadata/exif_gps.cpp
  ${LIBRAW_DIR}/src/metadata/fuji.cpp
  ${LIBRAW_DIR}/src/metadata/hasselblad_model.cpp
  ${LIBRAW_DIR}/src/metadata/identify.cpp
  ${LIBRAW_DIR}/src/metadata/identify_tools.cpp
  ${LIBRAW_DIR}/src/metadata/kodak.cpp
  ${LIBRAW_DIR}/src/metadata/leica.cpp
  ${LIBRAW_DIR}/src/metadata/makernotes.cpp
  ${LIBRAW_DIR}/src/metadata/mediumformat.cpp
  ${LIBRAW_DIR}/src/metadata/minolta.cpp
  ${LIBRAW_DIR}/src/metadata/misc_parsers.cpp
  ${LIBRAW_DIR}/src/metadata/nikon.cpp
  ${LIBRAW_DIR}/src/metadata/normalize_model.cpp
  ${LIBRAW_DIR}/src/metadata/olympus.cpp
  ${LIBRAW_DIR}/src/metadata/p1.cpp
  ${LIBRAW_DIR}/src/metadata/pentax.cpp
  ${LIBRAW_DIR}/src/metadata/samsung.cpp
  ${LIBRAW_DIR}/src/metadata/sony.cpp
  ${LIBRAW_DIR}/src/metadata/tiff.cpp
  ${LIBRAW_DIR}/src/postprocessing/aspect_ratio.cpp
  ${LIBRAW_DIR}/src/postprocessing/dcraw_process.cpp
  ${LIBRAW_DIR}/src/postprocessing/mem_image.cpp
  ${LIBRAW_DIR}/src/postprocessing/postprocessing_aux.cpp
  ${LIBRAW_DIR}/src/postprocessing/postprocessing_utils.cpp
  ${LIBRAW_DIR}/src/postprocessing/postprocessing_utils_dcrdefs.cpp
  ${LIBRAW_DIR}/src/preprocessing/ext_preprocess.cpp
  ${LIBRAW_DIR}/src/preprocessing/raw2image.cpp
  ${LIBRAW_DIR}/src/preprocessing/subtract_black.cpp
  ${LIBRAW_DIR}/src/tables/cameralist.cpp
  ${LIBRAW_DIR}/src/tables/colorconst.cpp
  ${LIBRAW_DIR}/src/tables/colordata.cpp
  ${LIBRAW_DIR}/src/tables/wblists.cpp
  ${LIBRAW_DIR}/src/utils/curves.cpp
  ${LIBRAW_DIR}/src/utils/decoder_info.cpp
  ${LIBRAW_DIR}/src/utils/init_close_utils.cpp
  ${LIBRAW_DIR}/src/utils/open.cpp
  ${LIBRAW_DIR}/src/utils/phaseone_processing.cpp
  ${LIBRAW_DIR}/src/utils/read_utils.cpp
  ${LIBRAW_DIR}/src/utils/thumb_utils.cpp
  ${LIBRAW_DIR}/src/utils/utils_dcraw.cpp
  ${LIBRAW_DIR}/src/utils/utils_libraw.cpp
  ${LIBRAW_DIR}/src/write/apply_profile.cpp
  ${LIBRAW_DIR}/src/write/file_write.cpp
  ${LIBRAW_DIR}/src/write/tiff_writer.cpp
  ${LIBRAW_DIR}/src/x3f/x3f_parse_process.cpp
  ${LIBRAW_DIR}/src/x3f/x3f_utils_patched.cpp
)

target_include_directories(camraw PRIVATE
  ${LIBRAW_DIR}
  ${CMAKE_CURRENT_SOURCE_DIR}/camraw
)

# USE_ZLIB: LibRaw needs zlib for deflate-compressed DNGs (floating-point
# DNGs and some others); the NDK ships libz, linked below. LIBRAW_NOTHREADS:
# see native/libraw/VENDORING.md — this app only ever runs one decode at a
# time on a single isolate thread. No USE_JPEG: deliberately not linking
# libjpeg (not vendored, not in the NDK) — LibRaw's own internal
# lossless-JPEG decoder handles DNG's compressed tiles without it.
target_compile_definitions(camraw PRIVATE
  USE_ZLIB
  LIBRAW_NOTHREADS
)

find_library(Z_LIB z)

target_link_libraries(camraw PRIVATE ${Z_LIB})
