# Alexa Look

A Flutter app (Android-first, iOS-compatible) that applies a gentle, filmic,
cinema-style color look to your own photos and videos, via a 3D LUT that is
generated entirely from published, generic camera color-science constants.

## What it does

- One home-screen action, **Select media**: pick any mix of photos, RAW/DNG
  files, and videos from the gallery in a single multi-select. A **Browse
  files…** action covers anything the gallery picker can't surface (RAW/DNG,
  most notably). What each file actually *is* — photo, RAW, or video — is
  detected from its own content (magic bytes), not from which picker
  produced it or its file extension — see "Unified media selection" below.
- Pick exactly one file and it opens straight into the matching single-item
  editor (photo, RAW, or video); pick several (any mix) and they open in one
  unified batch screen, RAW included.
- **Share a photo or video into the app** from your gallery or another app
  (Android) and it's routed through that exact same logic — see "Share to
  app" below.
- Import a RAW/DNG photo (including a phone's Pro-mode/UltraRAW capture) and
  grade it through the same pipeline — see "RAW (DNG) photo support" below.
- The app applies a soft, desaturated, film-print-style grade: gentle shadow
  toe, healthy mid-tone contrast, and a soft highlight roll-off — not a heavy
  teal/orange grade.
- Adjust the strength of the effect with a **live-updating** intensity
  slider (photos), press-and-hold (or the Before/After toggle) to compare,
  and save the result — never overwriting your originals.
- After saving, a **results screen** shows what was exported this session as
  a thumbnail grid — tap a photo for a full-screen zoomable preview, tap a
  video to share/open it, and Share (per item, or all at once) via the
  system share sheet. "Saved to Alexa Look album" stays as the permanent
  record regardless of what you do with Share.

## Unified media selection

Every picked/shared file — whatever picker or app it came from — is
classified by its own **content**, not its extension or source, before
anything happens with it (`lib/core/media_detector.dart`): JPEG, PNG,
HEIC/HEIF, WebP and TIFF magic bytes, TIFF vs. DNG (by walking the TIFF IFD0
for the `DNGVersion` tag — reusing the IFD parser in
`lib/core/dng_preview.dart`), and MP4/MOV, Matroska/WebM, and AVI container
signatures. A file's extension is only ever consulted as a fallback, when
content sniffing is inconclusive.

That classification feeds a small, pure routing decision
(`lib/core/media_routing.dart`): exactly one supported file opens straight
into its single-item editor (a RAW file goes through the same RAW decode
chain either way); more than one — any mix of photo, RAW, and video — opens
the unified batch screen, which now handles RAW items too (previously batch
had no RAW path). Anything unrecognized is reported per-file without
blocking the rest of the selection.

## Share to app (Android)

Alexa Look registers as a share target for images and videos
(`ACTION_SEND`/`ACTION_SEND_MULTIPLE`, `image/*` and `video/*`, plus
`application/octet-stream` for galleries that share a DNG under that generic
mime type) via `receive_sharing_intent`. Files shared in — whether the app
was already open or launched fresh by the share — flow through the exact
same content-classification-and-routing logic as the in-app pickers. This is
**Android-only** for now; an iOS share extension is out of scope for this
release.

Processing continues only while the app is open — there is no background
service keeping a batch run alive if you switch away mid-run. A wakelock is
held for the duration of a batch run so the screen itself doesn't sleep and
interrupt it, but backgrounding the app (or the OS killing it) still stops
processing; whatever had already finished and saved stays saved.

## Saving: dedicated album, never overwrite

Every graded photo and video is saved into its own **"Alexa Look"** gallery
album — never mixed into your camera roll's default album, and never written
over an existing file. Each output gets a unique, collision-free name of the
form `alexa_look_<yyyyMMdd_HHmmss>_<uuid-suffix>` (see
[`lib/core/output_naming.dart`](lib/core/output_naming.dart)), so even many
photos saved in the same batch run within the same second never clash. Your
original photo/video file is **never modified or deleted** — the app only
ever reads it and writes a brand-new file elsewhere.

## Performance: multicore photo grading

Photo grading is parallelized across CPU cores:

- The image is split into horizontal row bands — one per
  `(Platform.numberOfProcessors - 1).clamp(2, 8)` — and each band is graded
  concurrently in its own isolate via `Isolate.run`, then reassembled
  ([`lib/features/photo/photo_processor.dart`](lib/features/photo/photo_processor.dart),
  `gradeRgbaMulticore`). The LUT lattice is sent to each isolate as a flat,
  compact `Float32List` (`CubeLut.toFloat32Lattice()`) rather than
  re-parsing the `.cube` text per band.
- The trilinear-interpolation inner loop
  (`CubeLut.applyLutToRgbaBand`) is written as a single tight pass over the
  pixel buffer with precomputed per-channel scale factors, no `Color3`
  allocation, and no per-pixel function calls — the interpolation math is
  inlined directly.
- A small (max ~1200px) downscaled **preview copy** is kept alongside the
  full-resolution image; dragging the intensity slider re-grades only that
  preview (throttled to one in-flight regrade at a time, latest value
  wins), so the slider feels effectively instant. The expensive
  full-resolution grade only runs once, right before saving.
- Photos are saved as JPEG (quality 95) instead of PNG — phone photos have
  no alpha to preserve, and JPEG encodes noticeably faster and smaller.

**Video** grading is ffmpeg-bound, not app-bound: `ffmpeg`'s `lut3d` filter
already saturates the codec, so the app passes `-threads 0` to let ffmpeg
use every available core for the encode itself; there's no per-frame Dart
work to parallelize the way there is for photos.

## How the look is derived — and what it is *not*

This app does **not** ship, embed, or derive from any ARRI-authored LUT,
preset, or other copyrighted color-science asset. Instead, `tool/generate_lut.dart`
*builds our own LUT from scratch* in pure Dart, using only generic, published
technical constants of the kind that ship in any camera's public color-science
documentation:

1. **Linearize** the input using the sRGB/Rec.709 EOTF (IEC 61966-2-1).
2. **Convert primaries** from linear Rec.709 to ALEXA Wide Gamut, using the
   inverse of the published AWG→Rec.709 conversion matrix.
3. **Encode to LogC3 (EI800)** using the published curve constants (`cut`,
   `a`, `b`, `c`, `d`, `e`, `f`).
4. **Apply an original "print" render**: a smooth, monotone-cubic S-curve
   (built with a Fritsch–Carlson spline through three anchor points — black,
   18% mid-gray, and white — that we chose ourselves) provides a gentle toe,
   mid-tone contrast, and a soft shoulder; the result is converted back
   through the AWG→Rec.709 matrix, given a mild, luma-weighted desaturation
   (heavier at the tonal extremes), then re-encoded with the sRGB OETF and
   clamped to `[0,1]`.

All of this math lives in [`lib/core/alexa_look.dart`](lib/core/alexa_look.dart),
with no Flutter dependency, so it's shared by both the LUT generator and the
test suite. The generator ([`tool/generate_lut.dart`](tool/generate_lut.dart))
samples that function on a 33×33×33 grid to produce
[`assets/luts/alexa_look_33.cube`](assets/luts/alexa_look_33.cube), a
standard Adobe/Iridas `.cube` file, formatted deterministically (fixed
6-decimal values) so it can be regenerated byte-for-byte identically — CI
regenerates it on every run and fails the build if it doesn't match what's
committed, so the shipped LUT can never silently drift from the math that
produced it.

At runtime:

- **Photos** are graded in-process: [`lib/core/cube_lut.dart`](lib/core/cube_lut.dart)
  parses the `.cube` file and applies it with trilinear interpolation,
  parallelized across background isolates (see "Performance" above), blended
  against the original by the intensity slider.
- **Videos** are graded with `ffmpeg`'s `lut3d` filter (via
  `ffmpeg_kit_flutter_new_full`, the LGPL build — no GPL codecs), pointed at
  a copy of the same `.cube` file in the app's documents directory. Note:
  ffmpeg's `lut3d` filter bakes the look at full strength — video doesn't
  support the intensity slider's continuous blend the way photos do (in
  batch mode, the shared intensity slider therefore only affects photos;
  videos are always graded at full strength, same as the single-video
  editor).

### Video encoding: hardware H.264 first, compatibility fallback

`lib/features/video/video_processor.dart` tries an ordered ladder of ffmpeg
encode commands per video and keeps the first one that succeeds:

1. **Hardware H.264** (`h264_mediacodec`, via the device's MediaCodec) at
   the source's own resolution and bit rate — the bundled
   `ffmpeg-kit-full` build has `--enable-mediacodec`/`--enable-jni`, and this
   plays back on virtually every modern phone's gallery/media player.
   MediaCodec availability can only be confirmed on-device, so this is
   always tried first; if it fails, ffmpeg is retried automatically.
2. **MPEG-4 compatibility fallback** (`-c:v mpeg4 -q:v 3`), scaled down to a
   max dimension of 1280px. This is the previous default codec — MPEG-4
   Part 2 (ASP) hardware decode support on modern phones is unreliable at
   full resolution, which is why a phone-recorded 1080p/4K clip graded with
   the old unconditional `mpeg4` pipeline could produce an mp4 the phone's
   own gallery app couldn't play. Downscaling keeps this fallback playable
   broadly.

Each of those is additionally tried with `-c:a copy` (fast, lossless) before
falling back to `-c:a aac -b:a 192k` if the source audio can't be
stream-copied into an mp4 container. Every attempt sets `-pix_fmt yuv420p`
explicitly (a modern phone's 10-bit HEVC/HDR source would otherwise carry an
incompatible pixel format into the output) and `-movflags +faststart`. The
save confirmation shows which encoder actually produced the file (e.g. "H.264
(hardware)" vs "MPEG-4 (compatibility)").

## Batch mode

Selecting more than one supported item from **Select media** (or **Browse
files…**, or a share-in — see "Unified media selection" above) opens a grid
of thumbnails with per-item status (queued / processing with progress / done
/ failed) and one shared intensity slider. Tapping
**"Apply look & save all"** processes everything in order — photos and RAW
files through the multicore pipeline (RAW decoded first via the same
fallback chain as the single-item RAW import, below), videos sequentially
through ffmpeg — saving each into the Alexa Look album as it finishes. The
run is cancellable between items (the item in flight is allowed to finish,
so nothing is left half-saved); anything already saved stays saved even if
you cancel or back out. Once the run finishes, the results screen (see
above) shows a grid of everything that was exported. Picking exactly one
item routes into the richer single-item editor instead of the batch grid.

## RAW (DNG) photo support

Picking (or sharing in) a single DNG raw photo — including a phone's
Pro-mode/UltraRAW capture — opens the same single-photo editor, routed there
automatically because the file's own bytes were recognized as DNG (see
"Unified media selection" above); a "Browse files…" pick still works too,
since a DNG usually can't be surfaced by the gallery picker in the first
place. Either way it's graded through the same look pipeline as any other
photo. Tested against the **Xiaomi 15 Ultra**'s Pro-mode RAW and UltraRAW
DNGs, but works with standard DNG files from any source.

### How it decodes a RAW file

On Android, decoding tries three approaches in order, stopping at the first
one that works (see [`lib/core/raw_import.dart`](lib/core/raw_import.dart)):

1. **LibRaw**, via `dart:ffi` — a real from-sensor-data raw demosaic, using
   the file's own embedded camera white balance and outputting sRGB. This is
   the primary path and gives the most faithful result.
2. **ffmpeg** (already bundled for video grading) renders a single frame of
   the DNG to PNG. ffmpeg's own DNG decoder doesn't do the same
   demosaic/white-balance work LibRaw does, so this can look flatter or
   darker — a reasonable fallback, not a replacement.
3. **Embedded JPEG preview extraction** — a small, dependency-free, pure-Dart
   TIFF/IFD parser ([`lib/core/dng_preview.dart`](lib/core/dng_preview.dart))
   that reads the DNG's own directory structure to find and extract the
   largest JPEG preview the camera already baked into the file (via
   `JpegIFOffset`/`JpegIFByteCount` or a single-strip JPEG-compressed IFD).

On **iOS**, there is no native decoder — LibRaw isn't built for iOS — so the
same fallback chain runs starting from step 2 (ffmpeg, then the embedded
preview). The editor shows a small **"RAW · LibRaw"** or
**"RAW · preview fallback"** badge so you always know which path produced
what you're looking at. If every step fails (a corrupt file, or a raw
variant with no recognizable structure), you get a clear error instead of a
silent bad result.

Whichever decoder ran, the result feeds into the exact same
`preparePhoto`/grading pipeline as a normally-picked photo — downscaled to
the same resolution cap, graded with the same LUT, saved to the same
dedicated **Alexa Look** album as a JPEG with the same collision-free naming
(see "Saving" above).

### LibRaw attribution & license

The primary Android decoder is built on a trimmed, vendored copy of
[**LibRaw**](https://www.libraw.org/) **0.21.5**
(`native/libraw/`, see
[`native/libraw/VENDORING.md`](native/libraw/VENDORING.md) for exactly what's
included and why), compiled into `libcamraw.so` alongside a small C++
wrapper ([`native/camraw/`](native/camraw/)) via
`android/app/build.gradle.kts`'s `externalNativeBuild` and
[`native/CMakeLists.txt`](native/CMakeLists.txt), and loaded at runtime
through hand-written `dart:ffi` bindings
([`lib/core/raw_decoder.dart`](lib/core/raw_decoder.dart)) — no `ffigen`,
just three bound functions.

LibRaw is dual-licensed under the **LGPL-2.1** and the **CDDL-1.0**; both
license texts and LibRaw's own copyright notice are included verbatim under
`native/libraw/` (`LICENSE.LGPL`, `LICENSE.CDDL`, `COPYRIGHT`). This app
loads LibRaw as a dynamically-linked shared library, which satisfies the
LGPL's linking terms. No LibRaw source is modified from upstream.

## App icon

The app icon is generated deterministically in pure Dart —
[`tool/generate_icon.dart`](tool/generate_icon.dart) uses only `package:image`
(no design tool, no external assets) to render a 1024×1024 charcoal panel
with a centered three-bar amber→warm-white→teal "waveform" motif and a
subtle vignette, plus an Android adaptive-icon foreground/background pair.
Running it twice produces byte-identical PNGs (enforced by
`test/generate_icon_test.dart`, and CI regenerates and diffs the committed
files the same way it does for the LUT).

To regenerate the source PNGs and re-run icon generation for both platforms:

```bash
dart run tool/generate_icon.dart      # writes assets/icon/*.png
dart run flutter_launcher_icons       # regenerates android/ and ios/ icon resources
```

Both the generated `assets/icon/*.png` sources and the platform-specific
icon resources under `android/app/src/main/res/` and
`ios/Runner/Assets.xcassets/AppIcon.appiconset/` are committed, so a normal
build doesn't need to run either step — only do so after changing the icon
art in `tool/generate_icon.dart`.

## Sample results

Real before/after output from the look, run on real free-license photos and
a free-license video clip through the app's actual processing code (not
mockups) — see [`docs/SAMPLES.md`](docs/SAMPLES.md) for the full set (four
photos plus a video, each with source + license) and how they were produced.

<table>
<tr><th>Before</th><th>After</th></tr>
<tr>
<td><img src="docs/samples/01_portrait_before.jpg" width="420"></td>
<td><img src="docs/samples/01_portrait_after.jpg" width="420"></td>
</tr>
</table>

## Trademark notice

**"ARRI"** and **"ALEXA"** are trademarks of Arnold & Richter Cine Technik
GmbH & Co. KG (ARRI AG). Alexa Look is an independent, fan-made app and is
**not affiliated with, endorsed by, or sponsored by ARRI**. It references
ARRI's published, generic technical color-science constants (the same kind of
public documentation any colorist uses to build a custom look) purely to
build its own original color transform — no ARRI software, LUTs, or other
copyrighted assets are used or distributed.

This same notice, plus the app version and a link to the open-source
licenses page, is shown in-app behind the version number at the bottom of
the home screen (the About sheet) — kept there rather than as permanent
home-screen text, to keep the home screen itself uncluttered.

## Building

Requires the Flutter SDK (this project targets Flutter 3.47+ / Dart 3.13+).

```bash
flutter pub get

# Regenerate the LUT (only needed if you change lib/core/alexa_look.dart):
dart run tool/generate_lut.dart

flutter analyze
flutter build apk --release   # Android
flutter build ios --release   # iOS (requires Xcode/macOS)
```

## Testing

```bash
flutter test
```

The suite covers:

- LogC3 encode/decode round-trip accuracy and monotonicity, including a
  known-value check (18% gray → LogC3 ≈ 0.391 at EI800).
- The AWG↔Rec.709 matrix inverse (`M · M⁻¹ ≈ I`).
- The full look pipeline: gray-axis neutrality, monotonicity, black/white
  behavior, the mid-gray target range, and output range clamping.
- The `.cube` parser (valid and malformed input) and trilinear interpolation
  (identity LUT round-trip, sane off-lattice sampling).
- The optimized bulk trilinear path (`CubeLut.applyLutToRgbaBand`) matching
  `CubeLut.apply` within 1 LSB across random pixels for a real, non-identity
  LUT.
- Multicore banded grading (`gradeRgbaMulticore`) producing byte-for-byte
  identical output to a single-pass grade, including an odd image height
  that doesn't divide evenly across isolates.
- A performance sanity bound: the bulk trilinear path grades a 1000×1000
  image well within a generous time budget, to catch pathological
  regressions (e.g. an accidental per-pixel allocation).
- Deterministic LUT generation (two runs produce identical bytes).
- Deterministic icon generation (two runs of each PNG variant produce
  identical bytes).
- Unique output-name generation: no collisions across thousands of names
  generated at the same instant.
- `BatchController`'s pure state-machine logic: queued → processing → done
  transitions, failure isolation (one failed item doesn't stop the rest),
  cancellation taking effect between items, and routing a RAW item through
  its own `processRaw` callback rather than the photo/video ones.
- The batch flow's RAW-item pipeline (`gradeRawBatchItem`) with an injected
  fake byte reader and decode step: read → decode → prepare → grade →
  encode wiring, monotonic progress reporting, and a decode failure
  propagating rather than being swallowed.
- The content-based media classifier (`classifyMediaBytes`) against
  synthetic byte fixtures for every format branch (JPEG, PNG, HEIC/HEIF,
  WebP, TIFF, DNG, MP4, MOV, Matroska/WebM, AVI), TIFF-vs-DNG discrimination
  via the `DNGVersion` IFD0 tag, and the extension fallback (case-insensitive,
  and only used when content sniffing is inconclusive — recognized content
  always wins over a misleading extension).
- The pure routing decision (`decideMediaRoute`) with injected fakes: one
  supported item → its single-item editor (photo, RAW, or video), several
  (any mix) → the unified batch screen, unsupported files filtered out and
  reported without blocking the rest, and an all-unsupported or empty
  selection routing nowhere.
- The results screen's non-widget model (`ResultsSession`): items/their temp
  files usable until `dispose`, "share all" gathering every item's path,
  `dispose` being idempotent, and a per-item delete failure not blocking the
  rest's cleanup.
- A widget smoke test asserting the home screen renders the unified
  "Select media" / "Browse files…" actions (and not the old four
  Photo/Video/Batch/RAW buttons or the "Licenses" link).
- The RAW/DNG embedded-preview parser (`extractLargestDngPreviewJpeg`)
  against hand-crafted TIFF/IFD byte structures: `JpegIFOffset` previews,
  single-strip JPEG-compressed-IFD previews, SubIFD traversal, picking the
  largest of several candidates, and graceful (non-throwing) handling of
  malformed/truncated input.
- The RAW decode fallback chain's control flow (`decodeRawFile`) with
  injected fake decoders: falling through past a declining or throwing step,
  chain order (an earlier success means later steps are never called), and
  every step failing producing a clear error.
- `RawDecoder`'s platform guard cleanly reporting the native LibRaw decoder
  unavailable (never crashing) when not running on Android — which is what
  every `flutter test` run exercises, since the suite runs on the host.
- The video encode command ladder (`buildVideoEncodeAttempts`): attempt
  ordering (hardware H.264 before the mpeg4 fallback, audio-copy before the
  AAC re-encode variant), the compatibility scale computation (max-dimension
  clamp, aspect preserved, even dimensions, never upscaling), the hardware
  bitrate choice, and `lut3d`/path escaping — plus the retry ladder itself
  (`runVideoEncodeLadder`) with injected fake attempt runners: falling
  through a failing attempt to the next, and every attempt failing
  surfacing the last one's ffmpeg log.

Native code (the vendored LibRaw + `native/camraw/` wrapper, see the RAW
section below) only compiles as part of an actual Android build — there's no
NDK available for `flutter test`/`flutter analyze` to build against, so it's
validated separately: every vendored `.cpp` file compiles cleanly with the
project's exact defines using the host's own C++ toolchain, and the wrapper
was additionally linked into a real `.so` and exercised end-to-end (version
string, an invalid-input error path, and a full successful decode of a
synthetic DNG) before this was merged.

## Project layout

```
lib/
  core/            Pure-Dart color science, .cube parser, LUT generation/apply, LUT asset loading,
                   output naming, RAW decode (dart:ffi bindings, DNG preview parser, fallback chain),
                   content-based media classification + routing (media_detector.dart, media_routing.dart)
  features/
    home/          Home screen (unified "Select media" + "Browse files…", share-intent handling,
                   the About sheet tucked behind the version number)
    photo/         Photo picking, multicore grading, live preview, save
    video/         Video picking, ffmpeg-based grading, progress, save
    batch/         Multi-select batch flow: models, state-machine controller, grid UI, RAW-item processing
    results/       Results screen shown after a save: thumbnail grid, full-screen preview, share
  theme/           App-wide dark theme, page transitions
native/
  CMakeLists.txt   Builds libcamraw.so (vendored LibRaw + the camraw wrapper) for Android
  libraw/          Vendored, trimmed LibRaw source + license files — see VENDORING.md
  camraw/          Thin extern "C" wrapper around LibRaw's C++ API
tool/
  generate_lut.dart   Deterministic LUT generator (dart run tool/generate_lut.dart)
  generate_icon.dart  Deterministic app icon generator (dart run tool/generate_icon.dart)
  apply_look.dart     Pure-Dart CLI that grades one photo through the app's real
                      pipeline (dart run tool/apply_look.dart <in> <out> [intensity]),
                      used to produce docs/SAMPLES.md's before/after images
assets/luts/       The generated, committed .cube LUT
assets/icon/       The generated, committed app icon source PNGs
docs/samples/      Before/after sample photos + video for docs/SAMPLES.md
test/              Unit + widget tests
```
