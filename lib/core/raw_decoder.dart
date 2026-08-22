/// Hand-written `dart:ffi` bindings for `libcamraw.so` — the vendored
/// LibRaw + thin C wrapper built from `native/` (see
/// `native/libraw/VENDORING.md` and `native/camraw/camraw.h`). Only three
/// native functions are bound; no ffigen, no generated code.
///
/// This is the primary decoder in the RAW import fallback chain (see
/// `lib/core/raw_import.dart`) — Android only, since that's the only
/// platform the native library is built for (see
/// `android/app/build.gradle.kts`'s `externalNativeBuild`).
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Thrown by [RawDecoder.decode] when LibRaw itself reports a decode
/// failure (unsupported/corrupt file, etc.) — as opposed to the decoder
/// simply being unavailable, which callers detect via [RawDecoder.tryLoad]
/// returning `null` rather than by catching an exception.
class RawDecodeFailure implements Exception {
  /// The raw LibRaw error code (see LibRaw's `LibRaw_errors` enum) —
  /// negative for a reported error, so this is never 0.
  final int libRawErrorCode;
  const RawDecodeFailure(this.libRawErrorCode);

  @override
  String toString() =>
      'RawDecodeFailure: LibRaw reported error code $libRawErrorCode';
}

/// The result of a successful [RawDecoder.decode] call: an 8-bit
/// interleaved RGB buffer (no alpha) of exactly `width * height * 3` bytes.
class RawDecodeResult {
  final Uint8List rgb;
  final int width;
  final int height;
  const RawDecodeResult({
    required this.rgb,
    required this.width,
    required this.height,
  });
}

typedef _CamrawDecodeNative = Int32 Function(
  Pointer<Uint8> data,
  Int32 len,
  Pointer<Int32> outW,
  Pointer<Int32> outH,
  Pointer<Pointer<Uint8>> outRgb,
);
typedef _CamrawDecodeDart = int Function(
  Pointer<Uint8> data,
  int len,
  Pointer<Int32> outW,
  Pointer<Int32> outH,
  Pointer<Pointer<Uint8>> outRgb,
);

typedef _CamrawFreeNative = Void Function(Pointer<Uint8> buf);
typedef _CamrawFreeDart = void Function(Pointer<Uint8> buf);

typedef _CamrawVersionNative = Pointer<Utf8> Function();
typedef _CamrawVersionDart = Pointer<Utf8> Function();

/// Loads and calls into `libcamraw.so`. Obtain an instance via
/// [RawDecoder.tryLoad] — never throws, returns `null` when the native
/// decoder isn't available (any non-Android platform, or the library/symbol
/// lookup fails for any reason) so callers can cleanly fall back to the
/// next decoder in the chain instead.
class RawDecoder {
  final _CamrawDecodeDart _decode;
  final _CamrawFreeDart _free;
  final _CamrawVersionDart _version;

  RawDecoder._(DynamicLibrary lib)
      : _decode = lib.lookupFunction<_CamrawDecodeNative, _CamrawDecodeDart>(
            'camraw_decode'),
        _free =
            lib.lookupFunction<_CamrawFreeNative, _CamrawFreeDart>('camraw_free'),
        _version = lib
            .lookupFunction<_CamrawVersionNative, _CamrawVersionDart>(
                'camraw_version');

  static RawDecoder? _cached;
  static bool _attempted = false;

  /// Attempts to load `libcamraw.so` and resolve its three exported
  /// functions, caching the result for the lifetime of the isolate (dynamic
  /// libraries and their FFI bindings are per-isolate — if this is called
  /// from inside a freshly spawned [Isolate.run], it loads fresh there too,
  /// which is cheap: the OS-level `dlopen` itself is cached by soname).
  ///
  /// Returns `null` (never throws) when unavailable: not running on
  /// Android, the shared library isn't present, or a symbol is missing.
  static RawDecoder? tryLoad() {
    if (_attempted) return _cached;
    _attempted = true;
    if (!Platform.isAndroid) return null;
    try {
      final lib = DynamicLibrary.open('libcamraw.so');
      _cached = RawDecoder._(lib);
    } catch (_) {
      _cached = null;
    }
    return _cached;
  }

  /// LibRaw's own version string (e.g. `"0.21.5"`), for diagnostics and the
  /// in-app licenses note.
  String get version => _version().toDartString();

  /// Decodes a fully-read raw/DNG file's bytes into an 8-bit RGB image via
  /// LibRaw, using the camera's embedded white balance, sRGB output, and
  /// LibRaw's default gentle auto-brightness (see `native/camraw/camraw.cpp`
  /// for the exact parameters). Blocking/CPU-bound — callers should run
  /// this inside [Isolate.run] rather than on the UI isolate.
  ///
  /// Throws [RawDecodeFailure] if LibRaw reports an error (unsupported or
  /// corrupt file, etc).
  RawDecodeResult decode(Uint8List bytes) {
    final input = malloc<Uint8>(bytes.length);
    final outW = malloc<Int32>();
    final outH = malloc<Int32>();
    final outRgb = malloc<Pointer<Uint8>>();
    try {
      input.asTypedList(bytes.length).setAll(0, bytes);
      final ret = _decode(input, bytes.length, outW, outH, outRgb);
      if (ret != 0) {
        throw RawDecodeFailure(ret);
      }
      final width = outW.value;
      final height = outH.value;
      final rgbPtr = outRgb.value;
      try {
        final size = width * height * 3;
        return RawDecodeResult(
          rgb: Uint8List.fromList(rgbPtr.asTypedList(size)),
          width: width,
          height: height,
        );
      } finally {
        _free(rgbPtr);
      }
    } finally {
      malloc.free(input);
      malloc.free(outW);
      malloc.free(outH);
      malloc.free(outRgb);
    }
  }
}
