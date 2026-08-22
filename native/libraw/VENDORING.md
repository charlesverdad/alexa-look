# Vendored LibRaw

This directory contains a trimmed copy of [LibRaw](https://www.libraw.org/)
(https://github.com/LibRaw/LibRaw), used to decode Adobe DNG raw photos on
Android via a small C wrapper (`native/camraw/`).

- **Version:** 0.21.5 (tag `0.21.5`)
- **Upstream commit:** `e8b172e2197c3d45b35ffa992f6cfd9c49fdc100`
- **Source:** https://github.com/LibRaw/LibRaw/tree/0.21.5
- **License:** dual LGPL-2.1 / CDDL-1.0 — see `LICENSE.LGPL`, `LICENSE.CDDL`,
  and `COPYRIGHT` in this directory (copied verbatim from upstream). This app
  loads LibRaw as a dynamically-linked shared library (`libcamraw.so`), which
  satisfies the LGPL-2.1 linking terms.

## What's included

Only what's needed to build the core decode/demosaic/postprocess library
(the same file set upstream's own `Makefile.devel` `library:` target
compiles into `lib/libraw.a`), with no optional third-party codec
dependencies:

- `libraw/` — the public API headers.
- `internal/` — internal headers shared by the library's own source files.
- `src/` — the library's `.cpp` sources, mirroring upstream's directory
  layout (`decoders/`, `demosaic/`, `metadata/`, `postprocessing/`,
  `preprocessing/`, `tables/`, `utils/`, `write/`, `x3f/`, plus the
  top-level `libraw_c_api.cpp` / `libraw_datastream.cpp`).

Excluded on purpose:

- `src/postprocessing/postprocessing_ph.cpp`,
  `src/preprocessing/preprocessing_ph.cpp`, `src/write/write_ph.cpp` — these
  are upstream's placeholder/stub implementations of `dcraw_process` /
  `dcraw_make_mem_image` / etc. for a "no postprocessing" build variant.
  They define the same symbols as the real
  `dcraw_process.cpp`/`raw2image.cpp`/`file_write.cpp` we do vendor, so
  including both would fail the link — this app needs the real
  implementations since it calls `dcraw_process`/`dcraw_make_mem_image`.
- Everything else in the upstream tree: samples, docs, build files for other
  toolchains (autotools, qmake, MSVC), `RawSpeed`/`RawSpeed3` (an optional
  external decoder integration, not built — see below), the DNG SDK/GPR SDK
  integration glue's *external* dependency (the glue source files
  `integration/rawspeed_glue.cpp` and `integration/dngsdk_glue.cpp` are
  vendored since they're part of the standard object list, but their bodies
  are `#ifdef USE_RAWSPEED` / `#ifdef USE_DNGSDK` guarded and compile to
  empty translation units here since neither macro is defined).

## Build configuration

Compiled by `native/CMakeLists.txt` with:

- `USE_ZLIB` defined, linked against the NDK's `libz` — needed for
  deflate-compressed DNGs.
- `LIBRAW_NOTHREADS` defined — this app decodes one file at a time from a
  single Dart isolate thread, so upstream's optional per-instance
  thread-local decode state (used for concurrent decodes sharing one
  `LibRaw` instance) is unnecessary; `LIBRAW_NOTHREADS` makes the library
  use plain function-local `static` state instead, avoiding a dependency on
  pthreads or LibRaw's TLS plumbing.
- **No** `USE_JPEG` / libjpeg — LibRaw's own internal lossless-JPEG decoder
  (in `unpack.cpp`/`decoders_dcraw.cpp`) handles the compressed tiles found
  in DNGs; `USE_JPEG` only gates an *external* libjpeg codepath used for a
  few vendor formats and for writing embedded thumbnails back out as JPEG,
  neither of which this app needs.
- **No** RawSpeed, RawSpeed3, DNG SDK, or GPR (GoPro) SDK — all optional,
  all require additional proprietary or third-party sources not vendored
  here, and none are required to decode standard DNG files (including
  Xiaomi's Pro-mode / UltraRAW DNGs).

## Updating

To refresh to a newer LibRaw release, re-derive the source file list from
upstream's `Makefile.devel` `LIB_OBJECTS` list (map each `object/NAME.o`
entry to the `.cpp` file with matching basename under `src/`, excluding the
`*_ph.cpp` placeholders as above), copy `libraw/`, `internal/`, and those
`.cpp` files here preserving their subdirectory paths, update
`native/CMakeLists.txt`'s source list to match, and update this file's
version/commit and the top-level README's attribution section.
