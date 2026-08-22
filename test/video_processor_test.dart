import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:alexa_look/features/video/video_processor.dart';

void main() {
  group('computeCompatScale', () {
    test('returns null (no scale filter) when already within bounds', () {
      expect(computeCompatScale(1280, 720), isNull);
      expect(computeCompatScale(1000, 1200), isNull);
      expect(computeCompatScale(1280, 1280), isNull);
    });

    test('never upscales a small source', () {
      expect(computeCompatScale(320, 240), isNull);
    });

    test('scales a landscape 4K source down to max dimension 1280, preserving aspect', () {
      final scale = computeCompatScale(3840, 2160);
      expect(scale, isNotNull);
      expect(scale!.width, 1280);
      // 2160 * (1280/3840) = 720 exactly.
      expect(scale.height, 720);
    });

    test('scales a portrait source down by its longest edge (height)', () {
      final scale = computeCompatScale(2160, 3840);
      expect(scale, isNotNull);
      expect(scale!.height, 1280);
      expect(scale.width, 720);
    });

    test('produces only even dimensions', () {
      // 4K-ish odd-prone source: pick dims that don't divide evenly.
      final scale = computeCompatScale(4001, 2251);
      expect(scale, isNotNull);
      expect(scale!.width.isEven, isTrue);
      expect(scale.height.isEven, isTrue);
    });

    test('clamps degenerate tiny results to at least 2px', () {
      final scale = computeCompatScale(1, 100000);
      expect(scale, isNotNull);
      expect(scale!.width, greaterThanOrEqualTo(2));
      expect(scale.height, greaterThanOrEqualTo(2));
    });

    test('treats non-positive dimensions as unknown (no scale filter)', () {
      expect(computeCompatScale(0, 1080), isNull);
      expect(computeCompatScale(1920, -1), isNull);
    });
  });

  group('computeHardwareBitrate', () {
    test('prefers a known positive source bit rate verbatim', () {
      expect(
        computeHardwareBitrate(sourceBitRateBps: 20000000, sourceWidth: 3840, sourceHeight: 2160),
        '20000000',
      );
    });

    test('ignores a non-positive source bit rate and falls back to resolution default', () {
      expect(
        computeHardwareBitrate(sourceBitRateBps: 0, sourceWidth: 1920, sourceHeight: 1080),
        '8M',
      );
      expect(
        computeHardwareBitrate(sourceBitRateBps: null, sourceWidth: 1920, sourceHeight: 1080),
        '8M',
      );
    });

    test('defaults to 12M for 4K-and-above when bit rate is unknown', () {
      expect(
        computeHardwareBitrate(sourceWidth: 3840, sourceHeight: 2160),
        '12M',
      );
    });

    test('defaults to 8M for 1080p and below, and when resolution is unknown', () {
      expect(computeHardwareBitrate(sourceWidth: 1920, sourceHeight: 1080), '8M');
      expect(computeHardwareBitrate(), '8M');
    });
  });

  group('buildVideoEncodeAttempts', () {
    List<VideoEncodeAttempt> build({
      bool hardwareEncoderAvailable = true,
      int? width,
      int? height,
      int? bitRate,
    }) =>
        buildVideoEncodeAttempts(
          inputPath: '/in/clip.mov',
          outputPath: '/out/graded.mp4',
          lutPath: "/luts/alexa's look.cube",
          hardwareEncoderAvailable: hardwareEncoderAvailable,
          sourceWidth: width,
          sourceHeight: height,
          sourceBitRateBps: bitRate,
        );

    test('orders hardware H.264 attempts before the mpeg4 compat fallback', () {
      final attempts = build(width: 1920, height: 1080);
      expect(attempts.map((a) => a.encoder), [
        VideoEncoder.hardwareH264,
        VideoEncoder.hardwareH264,
        VideoEncoder.compatMpeg4,
        VideoEncoder.compatMpeg4,
      ]);
    });

    test('tries audio copy before the AAC re-encode fallback, per encoder', () {
      final attempts = build(width: 1920, height: 1080);
      expect(attempts[0].command, contains('-c:a copy'));
      expect(attempts[1].command, contains('-c:a aac'));
      expect(attempts[2].command, contains('-c:a copy'));
      expect(attempts[3].command, contains('-c:a aac'));
    });

    test('omits hardware attempts entirely when unavailable', () {
      final attempts = build(hardwareEncoderAvailable: false, width: 1920, height: 1080);
      expect(attempts, hasLength(2));
      expect(attempts.every((a) => a.encoder == VideoEncoder.compatMpeg4), isTrue);
    });

    test('hardware attempts use h264_mediacodec with an explicit bitrate, no -q:v', () {
      final attempts = build(width: 3840, height: 2160);
      for (final a in attempts.where((a) => a.encoder == VideoEncoder.hardwareH264)) {
        expect(a.command, contains('-c:v h264_mediacodec'));
        expect(a.command, contains('-b:v 12M'));
        expect(a.command, isNot(contains('-q:v')));
      }
    });

    test('compat attempts use mpeg4 with -q:v 3 and no -b:v', () {
      final attempts = build(width: 1920, height: 1080);
      for (final a in attempts.where((a) => a.encoder == VideoEncoder.compatMpeg4)) {
        expect(a.command, contains('-c:v mpeg4 -q:v 3'));
        expect(a.command, isNot(contains('-b:v')));
      }
    });

    test('every attempt sets pix_fmt yuv420p and +faststart', () {
      for (final a in build(width: 1920, height: 1080)) {
        expect(a.command, contains('-pix_fmt yuv420p'));
        expect(a.command, contains('-movflags +faststart'));
      }
    });

    test('compat filter chain scales a large source down after the LUT, small source unscaled', () {
      final large = build(width: 3840, height: 2160)
          .firstWhere((a) => a.encoder == VideoEncoder.compatMpeg4);
      expect(large.command, contains('lut3d='));
      expect(large.command, contains(',scale=1280:720'));

      final small = build(width: 640, height: 480)
          .firstWhere((a) => a.encoder == VideoEncoder.compatMpeg4);
      expect(small.command, isNot(contains('scale=')));
    });

    test('falls back to an unscaled compat filter when source dimensions are unknown', () {
      final attempts = build();
      final compat = attempts.firstWhere((a) => a.encoder == VideoEncoder.compatMpeg4);
      expect(compat.command, isNot(contains('scale=')));
    });

    test('escapes the lut3d filter path (colons, quotes) and quotes in/out paths', () {
      final attempts = build(width: 1920, height: 1080);
      // The lut path contains an apostrophe, which must be backslash-escaped
      // inside the single-quoted filter argument.
      expect(attempts.first.command, contains(r"lut3d='/luts/alexa\'s look.cube'"));
      expect(attempts.first.command, contains('"/in/clip.mov"'));
      expect(attempts.first.command, contains('"/out/graded.mp4"'));
    });

    test('passes -threads 0 for the multi-core encode', () {
      for (final a in build(width: 1920, height: 1080)) {
        expect(a.command, contains('-threads 0'));
      }
    });
  });

  group('runVideoEncodeLadder', () {
    VideoEncodeAttempt attempt(VideoEncoder encoder, String desc) => VideoEncodeAttempt(
          encoder: encoder,
          command: 'irrelevant',
          description: desc,
        );

    test('returns the first attempt to succeed without trying the rest', () async {
      final attempts = [
        attempt(VideoEncoder.hardwareH264, 'first'),
        attempt(VideoEncoder.compatMpeg4, 'second'),
      ];
      final tried = <String>[];
      final encoder = await runVideoEncodeLadder(attempts, (a) async {
        tried.add(a.description);
        return const VideoAttemptOutcome.success();
      });
      expect(encoder, VideoEncoder.hardwareH264);
      expect(tried, ['first']);
    });

    test('falls back to the second attempt when the first fails', () async {
      final attempts = [
        attempt(VideoEncoder.hardwareH264, 'hw'),
        attempt(VideoEncoder.compatMpeg4, 'compat'),
      ];
      final tried = <String>[];
      final encoder = await runVideoEncodeLadder(attempts, (a) async {
        tried.add(a.description);
        if (a.description == 'hw') {
          return const VideoAttemptOutcome.failure('mediacodec unavailable');
        }
        return const VideoAttemptOutcome.success();
      });
      expect(encoder, VideoEncoder.compatMpeg4);
      expect(tried, ['hw', 'compat']);
    });

    test('tries every attempt in order and throws with the last failure log when all fail', () async {
      final attempts = [
        attempt(VideoEncoder.hardwareH264, 'a'),
        attempt(VideoEncoder.hardwareH264, 'b'),
        attempt(VideoEncoder.compatMpeg4, 'c'),
      ];
      final tried = <String>[];
      Future<void> run() async {
        await runVideoEncodeLadder(attempts, (a) async {
          tried.add(a.description);
          return VideoAttemptOutcome.failure('log for ${a.description}');
        });
      }

      await expectLater(run, throwsA(isA<VideoGradeException>()));
      expect(tried, ['a', 'b', 'c']);

      try {
        await run();
        fail('expected VideoGradeException');
      } on VideoGradeException catch (e) {
        expect(e.toString(), contains('log for c'));
        expect(e.toString(), contains('c'));
      }
    });

    test('propagates a non-VideoGradeException failure via the outer completer contract', () async {
      // runVideoEncodeLadder itself only throws VideoGradeException; callers
      // (gradeVideoToTempFile) are responsible for wrapping other errors.
      // This test documents that runVideoEncodeLadder does not wrap runAttempt
      // successes/failures beyond the VideoAttemptOutcome contract.
      final attempts = [attempt(VideoEncoder.compatMpeg4, 'only')];
      expect(
        () => runVideoEncodeLadder(attempts, (a) async => const VideoAttemptOutcome.failure(null)),
        throwsA(isA<VideoGradeException>()),
      );
    });
  });

  group('VideoEncoder.label', () {
    test('has distinct, human-readable labels', () {
      expect(VideoEncoder.hardwareH264.label, contains('H.264'));
      expect(VideoEncoder.compatMpeg4.label, contains('MPEG-4'));
      expect(VideoEncoder.hardwareH264.label, isNot(VideoEncoder.compatMpeg4.label));
    });
  });

  group('runVideoEncodeLadder cancellation', () {
    VideoEncodeAttempt attempt(VideoEncoder encoder, String desc) => VideoEncodeAttempt(
          encoder: encoder,
          command: 'irrelevant',
          description: desc,
        );

    test('a cancelled outcome aborts the ladder immediately: no further attempts run, '
        'and a distinct VideoGradeCancelledException is thrown (not VideoGradeException)', () async {
      final attempts = [
        attempt(VideoEncoder.hardwareH264, 'first'),
        attempt(VideoEncoder.hardwareH264, 'second'),
        attempt(VideoEncoder.compatMpeg4, 'third'),
      ];
      final tried = <String>[];
      Future<VideoEncoder> run() => runVideoEncodeLadder(attempts, (a) async {
            tried.add(a.description);
            if (a.description == 'first') {
              return const VideoAttemptOutcome.cancelled();
            }
            // Should never be reached: the ladder must stop at the first
            // cancelled outcome rather than falling through to a fallback
            // encode.
            return const VideoAttemptOutcome.success();
          });

      await expectLater(run, throwsA(isA<VideoGradeCancelledException>()));
      expect(tried, ['first']);
    });

    test('a cancellation midway through the ladder still stops it, even after earlier '
        'failures', () async {
      final attempts = [
        attempt(VideoEncoder.hardwareH264, 'a'),
        attempt(VideoEncoder.hardwareH264, 'b'),
        attempt(VideoEncoder.compatMpeg4, 'c'),
      ];
      final tried = <String>[];
      Future<VideoEncoder> run() => runVideoEncodeLadder(attempts, (a) async {
            tried.add(a.description);
            if (a.description == 'a') {
              return const VideoAttemptOutcome.failure('mediacodec unavailable');
            }
            if (a.description == 'b') {
              return const VideoAttemptOutcome.cancelled();
            }
            return const VideoAttemptOutcome.success();
          });

      await expectLater(run, throwsA(isA<VideoGradeCancelledException>()));
      expect(tried, ['a', 'b']);
    });

    test('VideoGradeCancelledException is not a VideoGradeException — callers must be '
        'able to tell a cancellation apart from a genuine encode failure', () {
      const cancelled = VideoGradeCancelledException();
      expect(cancelled, isNot(isA<VideoGradeException>()));
    });
  });

  group('VideoCancellationToken', () {
    test('starts uncancelled, and cancel() is a one-way, idempotent flip', () {
      final token = VideoCancellationToken();
      expect(token.isCancelled, isFalse);
      token.cancel();
      expect(token.isCancelled, isTrue);
      token.cancel(); // calling again must not throw or un-set anything.
      expect(token.isCancelled, isTrue);
    });
  });

  group('VideoGradeSession.cancel persists across the ladder (cancelRequested)', () {
    test('cancelRequested is false until cancel() is called', () {
      final session = VideoGradeSession(
        currentSessionId: () => null,
        cancellationToken: VideoCancellationToken(),
        result: Completer<VideoGradeResult>().future,
      );
      expect(session.cancelRequested, isFalse);
    });

    test('cancel() sets cancelRequested even when no ffmpeg session id exists yet — '
        'covers cancelling during ffprobe/startup, before any attempt has started', () {
      final session = VideoGradeSession(
        currentSessionId: () => null, // no attempt has started yet.
        cancellationToken: VideoCancellationToken(),
        result: Completer<VideoGradeResult>().future,
      );
      session.cancel();
      expect(session.cancelRequested, isTrue);
    });

    test('cancelRequested stays true across what would be several ladder attempts — '
        'the same token instance is shared by the whole session, not just one attempt', () {
      // No live ffmpeg session id here (`currentSessionId: () => null`) so
      // cancel() only exercises the token side, not a real
      // FFmpegKit.cancel() call — that requires plugin bindings this plain
      // unit test doesn't set up; the id != null path is a one-line
      // pass-through already covered by manual review and by the real
      // FFmpegKit integration the rest of the app relies on.
      final token = VideoCancellationToken();
      final session = VideoGradeSession(
        currentSessionId: () => null,
        cancellationToken: token,
        result: Completer<VideoGradeResult>().future,
      );
      session.cancel();
      expect(token.isCancelled, isTrue);
      expect(session.cancelRequested, isTrue);
      // A fresh session built from the *same* token (as gradeVideoToTempFile
      // does when a caller passes its own cancellationToken across what
      // amounts to the same logical grading run) sees the cancellation too.
      final sameTokenSession = VideoGradeSession(
        currentSessionId: () => null,
        cancellationToken: token,
        result: Completer<VideoGradeResult>().future,
      );
      expect(sameTokenSession.cancelRequested, isTrue);
    });
  });

  group('attemptOutcomeIfAlreadyCancelled — the "before starting each ladder attempt" check', () {
    test('returns null (proceed normally) when the token has not been cancelled', () {
      expect(attemptOutcomeIfAlreadyCancelled(VideoCancellationToken()), isNull);
    });

    test('returns a cancelled outcome, without ever touching ffmpeg, once the token is '
        'cancelled — covers cancelling during ffprobe/startup or in the gap between two '
        'ladder attempts', () {
      final token = VideoCancellationToken()..cancel();
      final outcome = attemptOutcomeIfAlreadyCancelled(token);
      expect(outcome, isNotNull);
      expect(outcome!.cancelled, isTrue);
      expect(outcome.success, isFalse);
    });
  });

  group('resolveAttemptOutcome — the "after each attempt completes" check', () {
    test('reports success when ffmpeg succeeded and no cancellation was requested', () {
      final outcome = resolveAttemptOutcome(
        token: VideoCancellationToken(),
        ffmpegSuccess: true,
        ffmpegCancelled: false,
      );
      expect(outcome.success, isTrue);
    });

    test('reports cancelled when ffmpeg itself reports a cancelled return code', () {
      final outcome = resolveAttemptOutcome(
        token: VideoCancellationToken(),
        ffmpegSuccess: false,
        ffmpegCancelled: true,
      );
      expect(outcome.cancelled, isTrue);
    });

    test('reports failure (preserving the log) for a genuine, non-cancelled failure', () {
      final outcome = resolveAttemptOutcome(
        token: VideoCancellationToken(),
        ffmpegSuccess: false,
        ffmpegCancelled: false,
        failureLog: 'boom',
      );
      expect(outcome.success, isFalse);
      expect(outcome.cancelled, isFalse);
      expect(outcome.log, 'boom');
    });

    test('a cancelled token overrides a reported ffmpeg SUCCESS — the completion race this '
        'app must not lose: an attempt finishing just as cancel() is called must never be '
        'treated as a usable, savable result', () {
      final token = VideoCancellationToken()..cancel();
      final outcome = resolveAttemptOutcome(
        token: token,
        ffmpegSuccess: true,
        ffmpegCancelled: false,
      );
      expect(outcome.success, isFalse);
      expect(outcome.cancelled, isTrue);
    });

    test('a cancelled token overrides a reported ffmpeg FAILURE too — otherwise an attempt '
        'that happened to fail naturally right as cancel() was requested would fall through '
        'to the next fallback attempt instead of stopping the ladder', () {
      final token = VideoCancellationToken()..cancel();
      final outcome = resolveAttemptOutcome(
        token: token,
        ffmpegSuccess: false,
        ffmpegCancelled: false,
        failureLog: 'mediacodec unavailable',
      );
      expect(outcome.cancelled, isTrue);
      expect(outcome.success, isFalse);
    });
  });
}
