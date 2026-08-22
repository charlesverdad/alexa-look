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

import '../../core/output_naming.dart';

/// Thrown when ffmpeg fails to grade a video.
class VideoGradeException implements Exception {
  final String message;
  const VideoGradeException(this.message);

  @override
  String toString() => message;
}

/// The outcome of a single [gradeVideoToTempFile] call: the ffmpeg session
/// id (so a caller can [FFmpegKit.cancel] it) and a future that resolves to
/// the graded file's path once encoding finishes.
class VideoGradeSession {
  final int? sessionId;
  final Future<String> outputPath;

  const VideoGradeSession({required this.sessionId, required this.outputPath});
}

/// Grades the video at [inputPath] with the `.cube` LUT at [lutPath] via
/// ffmpeg's `lut3d` filter, writing the result to a uniquely-named temp
/// file. Video encode speed is codec-bound, not app-bound, so this passes
/// `-threads 0` to let ffmpeg use every available core for the encode.
///
/// [onProgress] is called with a 0..1 fraction as ffmpeg reports its
/// position against the probed input duration (never called if the duration
/// can't be determined). Returns once ffmpeg has started; await
/// [VideoGradeSession.outputPath] for completion, or cancel via
/// `FFmpegKit.cancel(session.sessionId)`.
Future<VideoGradeSession> gradeVideoToTempFile({
  required String inputPath,
  required String lutPath,
  void Function(double progress)? onProgress,
}) async {
  final tempDir = await getTemporaryDirectory();
  final outputPath = '${tempDir.path}/${generateUniqueOutputName()}.mp4';

  double? durationSeconds;
  final probeSession = await FFprobeKit.getMediaInformation(inputPath);
  final info = probeSession.getMediaInformation();
  final durationStr = info?.getDuration();
  if (durationStr != null) {
    durationSeconds = double.tryParse(durationStr);
  }

  final escapedLutPath = _escapeFfmpegFilterPath(lutPath);
  // mpeg4 + copy audio are both always available in the LGPL ffmpeg build
  // (no libx264/GPL codecs required). -threads 0 lets ffmpeg pick the
  // thread count itself (all available cores) for the encode.
  final command = "-y -threads 0 -i ${_quotePath(inputPath)} "
      "-vf lut3d=$escapedLutPath "
      "-c:v mpeg4 -q:v 3 -c:a copy -threads 0 "
      "${_quotePath(outputPath)}";

  final completer = Completer<String>();
  final session = await FFmpegKit.executeAsync(
    command,
    (completedSession) async {
      final returnCode = await completedSession.getReturnCode();
      final success = ReturnCode.isSuccess(returnCode);
      if (success) {
        completer.complete(outputPath);
      } else {
        final logs = await completedSession.getOutput();
        completer.completeError(
          VideoGradeException('ffmpeg failed (code $returnCode).\n${logs ?? ''}'),
        );
      }
    },
    null,
    (Statistics stats) {
      if (onProgress == null || durationSeconds == null || durationSeconds == 0) {
        return;
      }
      final processedSeconds = stats.getTime() / 1000.0;
      final fraction = (processedSeconds / durationSeconds).clamp(0.0, 1.0);
      onProgress(fraction);
    },
  );

  return VideoGradeSession(
    sessionId: session.getSessionId(),
    outputPath: completer.future,
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
