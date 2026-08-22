/// Shared ffmpeg-based video grading pipeline, used by both the single-video
/// editor ([VideoScreen]) and the batch flow so the two never drift.
library;

import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/return_code.dart';
import 'package:ffmpeg_kit_flutter_new_full/statistics.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/cancellation.dart';
import '../../core/output_naming.dart';

/// Thrown when every ffmpeg encode attempt fails to grade a video.
class VideoGradeException implements Exception {
  final String message;
  const VideoGradeException(this.message);

  @override
  String toString() => message;
}

/// Thrown when [VideoGradeSession.cancel] stopped the in-flight ffmpeg
/// attempt before it finished. Distinct from [VideoGradeException]
/// (a genuine encode failure) so callers can tell the two apart: a
/// cancellation should stop silently — no error UI, nothing saved — while a
/// real failure should be surfaced. See [CancelledException].
class VideoGradeCancelledException implements CancelledException {
  const VideoGradeCancelledException();

  @override
  String toString() => 'Video grading was cancelled.';
}

/// Which video encoder actually produced a graded output. Surfaced in the UI
/// so a user can see whether they got the sharp hardware path or the
/// compatibility fallback.
enum VideoEncoder {
  /// Hardware-accelerated H.264 via the device's MediaCodec
  /// (`h264_mediacodec`). Full source resolution, decodes on virtually every
  /// modern phone's gallery/media player. Requires the bundled ffmpeg build
  /// to have `--enable-mediacodec`/`--enable-jni` (it does, as of
  /// ffmpeg-kit-full 2.2.1) and a device whose hardware encoder ffmpeg can
  /// actually open at runtime — this can't be verified ahead of time from
  /// Dart, so it's always attempted first and the ladder falls back
  /// automatically if it fails.
  hardwareH264,

  /// Software MPEG-4 Part 2 (`mpeg4`), scaled down to a max dimension of
  /// 1280px. MPEG-4 ASP hardware decode support on modern phones is
  /// unreliable at full resolution (the original bug), but software decode
  /// at this size plays broadly. Used when hardware encoding isn't available
  /// or fails at runtime.
  compatMpeg4;

  /// Short label surfaced in the UI, e.g. in the save confirmation.
  String get label => switch (this) {
        VideoEncoder.hardwareH264 => 'H.264 (hardware)',
        VideoEncoder.compatMpeg4 => 'MPEG-4 (compatibility)',
      };
}

/// The outcome of a successful [gradeVideoToTempFile] call: the graded
/// file's path and which encoder produced it.
class VideoGradeResult {
  final String path;
  final VideoEncoder encoder;
  const VideoGradeResult({required this.path, required this.encoder});
}

/// One ffmpeg encode attempt in the compatibility ladder: a fully-built
/// command line plus metadata for logging/testing.
class VideoEncodeAttempt {
  final VideoEncoder encoder;
  final String command;

  /// Human-readable description of this attempt (encoder + audio strategy),
  /// used in failure logs when the whole ladder is exhausted.
  final String description;

  const VideoEncodeAttempt({
    required this.encoder,
    required this.command,
    required this.description,
  });
}

/// The outcome of running a single [VideoEncodeAttempt].
class VideoAttemptOutcome {
  final bool success;

  /// True when the attempt was stopped by [VideoGradeSession.cancel] (an
  /// ffmpeg return code of [ReturnCode.isCancel]) rather than failing on its
  /// own — mutually exclusive with [success]. A cancelled attempt aborts the
  /// whole ladder (see [runVideoEncodeLadder]) instead of falling through to
  /// the next fallback encode.
  final bool cancelled;

  /// ffmpeg's log output, populated on failure for diagnostics.
  final String? log;

  const VideoAttemptOutcome.success()
      : success = true,
        cancelled = false,
        log = null;
  const VideoAttemptOutcome.failure(this.log)
      : success = false,
        cancelled = false;
  const VideoAttemptOutcome.cancelled()
      : success = false,
        cancelled = true,
        log = null;
}

/// The live session backing an in-flight [gradeVideoToTempFile] call. Since
/// the compatibility ladder may run several ffmpeg sessions in sequence,
/// there's no single fixed session id to expose — [cancel] always targets
/// whichever attempt is currently running.
class VideoGradeSession {
  final int? Function() _currentSessionId;
  final Future<VideoGradeResult> result;

  // The public constructor param is intentionally named differently from
  // the private field it fills, so an initializing formal doesn't apply.
  const VideoGradeSession({
    required int? Function() currentSessionId,
    required this.result,
    // ignore: prefer_initializing_formals
  }) : _currentSessionId = currentSessionId;

  /// The ffmpeg session id currently in flight, if any.
  int? get sessionId => _currentSessionId();

  /// Cancels whichever encode attempt is currently running.
  void cancel() {
    final id = _currentSessionId();
    if (id != null) {
      FFmpegKit.cancel(id);
    }
  }
}

/// The audio handling strategy for one encode attempt.
class _AudioVariant {
  final String description;
  final String args;
  const _AudioVariant(this.description, this.args);
}

/// Stream-copying the source audio is fastest and lossless, and works for
/// the AAC audio virtually every phone-recorded video already carries. A
/// small minority of sources have audio ffmpeg can't stream-copy into an
/// mp4 container (e.g. an unusual codec) — for those, re-encoding to AAC is
/// the fallback.
const _audioVariants = [
  _AudioVariant('audio copy', '-c:a copy'),
  _AudioVariant('AAC audio', '-c:a aac -b:a 192k'),
];

/// The longest edge a compatibility-mode (`mpeg4`) output is scaled down to.
/// MPEG-4 ASP hardware decoders on modern phones are unreliable above this,
/// but broadly support it.
const int kCompatMaxDimension = 1280;

/// Computes the scaled-down `width:height` for compatibility-mode encoding,
/// preserving aspect ratio and producing only even dimensions (required for
/// `yuv420p`). Returns `null` when the source is already at or below
/// [maxDimension] on its longest edge — never upscale.
({int width, int height})? computeCompatScale(
  int sourceWidth,
  int sourceHeight, {
  int maxDimension = kCompatMaxDimension,
}) {
  if (sourceWidth <= 0 || sourceHeight <= 0) return null;
  final longest = sourceWidth > sourceHeight ? sourceWidth : sourceHeight;
  if (longest <= maxDimension) return null;

  final scale = maxDimension / longest;
  var width = (sourceWidth * scale).round();
  var height = (sourceHeight * scale).round();
  // yuv420p requires even dimensions.
  if (width.isOdd) width -= 1;
  if (height.isOdd) height -= 1;
  if (width < 2) width = 2;
  if (height < 2) height = 2;
  return (width: width, height: height);
}

/// Picks a `-b:v` value for the hardware H.264 encoder (MediaCodec ignores
/// `-q:v`, so an explicit bitrate is required). Prefers the source's own
/// bit rate when ffprobe reported one, so grading doesn't gratuitously
/// re-compress; otherwise falls back to a resolution-based default.
String computeHardwareBitrate({
  int? sourceBitRateBps,
  int? sourceWidth,
  int? sourceHeight,
}) {
  if (sourceBitRateBps != null && sourceBitRateBps > 0) {
    return '$sourceBitRateBps';
  }
  final longest = (sourceWidth != null && sourceHeight != null)
      ? (sourceWidth > sourceHeight ? sourceWidth : sourceHeight)
      : null;
  // 4K (and anything unusually large) gets more headroom than 1080p/below.
  if (longest != null && longest >= 3000) return '12M';
  return '8M';
}

/// Builds the ordered ladder of ffmpeg commands to try for grading
/// [inputPath] into [outputPath] with the `.cube` LUT at [lutPath].
///
/// Order: hardware H.264 (audio copy, then AAC) when
/// [hardwareEncoderAvailable], followed by the `mpeg4` compatibility
/// fallback (audio copy, then AAC) — always included, since MediaCodec
/// availability can only be confirmed by actually trying it on-device.
/// `gradeVideoToTempFile` always passes `hardwareEncoderAvailable: true`;
/// the parameter exists so the ladder's shape is directly testable.
List<VideoEncodeAttempt> buildVideoEncodeAttempts({
  required String inputPath,
  required String outputPath,
  required String lutPath,
  required bool hardwareEncoderAvailable,
  int? sourceWidth,
  int? sourceHeight,
  int? sourceBitRateBps,
}) {
  final escapedLutPath = _escapeFfmpegFilterPath(lutPath);
  final quotedIn = _quotePath(inputPath);
  final quotedOut = _quotePath(outputPath);
  final attempts = <VideoEncodeAttempt>[];

  if (hardwareEncoderAvailable) {
    final bitrate = computeHardwareBitrate(
      sourceBitRateBps: sourceBitRateBps,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
    );
    for (final audio in _audioVariants) {
      attempts.add(VideoEncodeAttempt(
        encoder: VideoEncoder.hardwareH264,
        description: 'hardware H.264 (${audio.description})',
        command: '-y -threads 0 -i $quotedIn '
            '-vf lut3d=$escapedLutPath '
            '-c:v h264_mediacodec -b:v $bitrate -pix_fmt yuv420p '
            '${audio.args} -movflags +faststart '
            '$quotedOut',
      ));
    }
  }

  final scale = (sourceWidth != null && sourceHeight != null)
      ? computeCompatScale(sourceWidth, sourceHeight)
      : null;
  final vf = scale == null
      ? 'lut3d=$escapedLutPath'
      : 'lut3d=$escapedLutPath,scale=${scale.width}:${scale.height}';
  for (final audio in _audioVariants) {
    attempts.add(VideoEncodeAttempt(
      encoder: VideoEncoder.compatMpeg4,
      description: 'MPEG-4 compatibility (${audio.description})',
      command: '-y -threads 0 -i $quotedIn '
          '-vf $vf '
          '-c:v mpeg4 -q:v 3 -pix_fmt yuv420p '
          '${audio.args} -movflags +faststart '
          '$quotedOut',
    ));
  }

  return attempts;
}

/// Runs [attempts] in order via [runAttempt], returning the encoder of the
/// first one that succeeds. If every attempt fails, throws a
/// [VideoGradeException] carrying the last attempt's log output. If an
/// attempt comes back [VideoAttemptOutcome.cancelled], the ladder stops
/// immediately — it does *not* fall through to the next fallback encode —
/// and throws [VideoGradeCancelledException] instead: a user-cancelled
/// attempt isn't a failure to recover from, it's a request to stop.
///
/// This is the test seam for the retry ladder: production code
/// ([gradeVideoToTempFile]) passes a runner backed by real ffmpeg sessions;
/// tests pass a fake that succeeds/fails/cancels by index without touching
/// ffmpeg.
Future<VideoEncoder> runVideoEncodeLadder(
  List<VideoEncodeAttempt> attempts,
  Future<VideoAttemptOutcome> Function(VideoEncodeAttempt attempt) runAttempt,
) async {
  String? lastLog;
  String? lastDescription;
  for (final attempt in attempts) {
    final outcome = await runAttempt(attempt);
    if (outcome.success) return attempt.encoder;
    if (outcome.cancelled) throw const VideoGradeCancelledException();
    lastLog = outcome.log;
    lastDescription = attempt.description;
  }
  throw VideoGradeException(
    'All encode attempts failed. Last attempt: ${lastDescription ?? 'none'}.\n'
    '${lastLog ?? ''}',
  );
}

/// Grades the video at [inputPath] with the `.cube` LUT at [lutPath] via
/// ffmpeg's `lut3d` filter, writing the result to a uniquely-named temp
/// file. Tries hardware H.264 first, falling back through the
/// compatibility ladder built by [buildVideoEncodeAttempts] (see there for
/// the exact order) if an attempt fails. Video encode speed is codec-bound,
/// not app-bound, so every command passes `-threads 0` to let ffmpeg use
/// every available core.
///
/// [onProgress] is called with a 0..1 fraction as ffmpeg reports its
/// position against the probed input duration (never called if the duration
/// can't be determined; resets to 0 at the start of each retry attempt).
/// Returns once the first attempt's ffmpeg session has started; await
/// [VideoGradeSession.result] for completion, or call
/// [VideoGradeSession.cancel] to stop whichever attempt is currently
/// running.
Future<VideoGradeSession> gradeVideoToTempFile({
  required String inputPath,
  required String lutPath,
  void Function(double progress)? onProgress,
}) async {
  final tempDir = await getTemporaryDirectory();
  final outputPath = '${tempDir.path}/${generateUniqueOutputName()}.mp4';

  double? durationSeconds;
  int? sourceWidth;
  int? sourceHeight;
  int? sourceBitRateBps;

  final probeSession = await FFprobeKit.getMediaInformation(inputPath);
  final info = probeSession.getMediaInformation();
  final durationStr = info?.getDuration();
  if (durationStr != null) {
    durationSeconds = double.tryParse(durationStr);
  }
  for (final stream in info?.getStreams() ?? const []) {
    if (stream.getType() == 'video') {
      sourceWidth = stream.getWidth();
      sourceHeight = stream.getHeight();
      final streamBitrate = stream.getBitrate();
      sourceBitRateBps = streamBitrate != null ? int.tryParse(streamBitrate) : null;
      break;
    }
  }
  sourceBitRateBps ??= () {
    final formatBitrate = info?.getBitrate();
    return formatBitrate != null ? int.tryParse(formatBitrate) : null;
  }();

  final attempts = buildVideoEncodeAttempts(
    inputPath: inputPath,
    outputPath: outputPath,
    lutPath: lutPath,
    hardwareEncoderAvailable: true,
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
    sourceBitRateBps: sourceBitRateBps,
  );

  int? currentSessionId;
  var firstSessionStarted = false;
  final sessionStartedCompleter = Completer<void>();
  final resultCompleter = Completer<VideoGradeResult>();

  Future<VideoAttemptOutcome> runAttempt(VideoEncodeAttempt attempt) {
    final outcomeCompleter = Completer<VideoAttemptOutcome>();
    FFmpegKit.executeAsync(
      attempt.command,
      (completedSession) async {
        final returnCode = await completedSession.getReturnCode();
        if (ReturnCode.isSuccess(returnCode)) {
          outcomeCompleter.complete(const VideoAttemptOutcome.success());
        } else if (ReturnCode.isCancel(returnCode)) {
          // FFmpegKit.cancel() (via VideoGradeSession.cancel) makes the
          // session return this code — it is not a failure, and must not be
          // treated like one: runVideoEncodeLadder aborts the whole ladder
          // on a cancelled outcome instead of falling through to the next
          // fallback encode.
          outcomeCompleter.complete(const VideoAttemptOutcome.cancelled());
        } else {
          final logs = await completedSession.getOutput();
          outcomeCompleter.complete(
            VideoAttemptOutcome.failure('ffmpeg failed (code $returnCode).\n${logs ?? ''}'),
          );
        }
      },
      null,
      (Statistics stats) {
        if (onProgress == null || durationSeconds == null || durationSeconds == 0) {
          return;
        }
        final processedSeconds = stats.getTime() / 1000.0;
        onProgress((processedSeconds / durationSeconds).clamp(0.0, 1.0));
      },
    ).then((session) {
      currentSessionId = session.getSessionId();
      if (!firstSessionStarted) {
        firstSessionStarted = true;
        sessionStartedCompleter.complete();
      }
    });
    return outcomeCompleter.future;
  }

  unawaited(() async {
    try {
      final encoder = await runVideoEncodeLadder(attempts, runAttempt);
      resultCompleter.complete(VideoGradeResult(path: outputPath, encoder: encoder));
    } on VideoGradeCancelledException catch (e) {
      // Whichever attempt was cancelled may have already written a partial
      // output file before ffmpeg tore it down — clean it up so it doesn't
      // linger in the temp dir (and, crucially, so nothing downstream can
      // mistake it for a finished, savable result).
      unawaited(deleteTempVideoBestEffort(outputPath));
      resultCompleter.completeError(e);
    } catch (e) {
      resultCompleter.completeError(e is VideoGradeException ? e : VideoGradeException('$e'));
    } finally {
      if (!firstSessionStarted) {
        firstSessionStarted = true;
        sessionStartedCompleter.complete();
      }
    }
  }());

  await sessionStartedCompleter.future;

  return VideoGradeSession(
    currentSessionId: () => currentSessionId,
    result: resultCompleter.future,
  );
}

/// Escapes a filesystem path for safe use as the `lut3d` filter's file
/// argument inside an ffmpeg filtergraph: backslashes and colons must be
/// escaped, and the whole path is then wrapped in single quotes to protect
/// any other filtergraph-special characters (commas, spaces, brackets).
String _escapeFfmpegFilterPath(String path) {
  final escaped = path
      .replaceAll('\\', '\\\\')
      .replaceAll(':', '\\:')
      .replaceAll("'", "\\'");
  return "'$escaped'";
}

/// Quotes a path for use as a plain ffmpeg command-line argument (input or
/// output file), so paths containing spaces survive ffmpeg's own argument
/// tokenizer.
String _quotePath(String path) => '"${path.replaceAll('"', '\\"')}"';

/// Best-effort deletion of a temp video file once it has been copied into
/// the gallery — a failure here shouldn't surface as a user-facing error.
Future<void> deleteTempVideoBestEffort(String path) async {
  try {
    await File(path).delete();
  } catch (_) {
    // Ignore — nothing useful to do if cleanup fails.
  }
}
