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
}
