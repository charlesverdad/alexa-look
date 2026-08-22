// Tests for the pure routing decision logic (lib/core/media_routing.dart):
// no filesystem, no picker, no Flutter widget tree — just
// MediaDetectionResult in, MediaRoute out.

import 'package:flutter_test/flutter_test.dart';
import 'package:alexa_look/core/media_detector.dart';
import 'package:alexa_look/core/media_routing.dart';

RoutableMedia _media(String path, MediaFormat format, {bool byExtension = false}) {
  return RoutableMedia(
    path: path,
    detection: MediaDetectionResult(format, byExtensionFallback: byExtension),
  );
}

void main() {
  group('decideMediaRoute', () {
    test('a single photo routes to OpenPhotoEditor', () {
      final decision = decideMediaRoute([_media('a.jpg', MediaFormat.jpeg)]);
      expect(decision.route, isA<OpenPhotoEditor>());
      expect((decision.route as OpenPhotoEditor).media.path, 'a.jpg');
      expect(decision.unsupported, isEmpty);
    });

    test('a single DNG routes to OpenRawEditor (the RAW path)', () {
      final decision = decideMediaRoute([_media('a.dng', MediaFormat.dng)]);
      expect(decision.route, isA<OpenRawEditor>());
      expect((decision.route as OpenRawEditor).media.path, 'a.dng');
    });

    test('a single video routes to OpenVideoEditor', () {
      final decision = decideMediaRoute([_media('a.mp4', MediaFormat.mp4)]);
      expect(decision.route, isA<OpenVideoEditor>());
      expect((decision.route as OpenVideoEditor).media.path, 'a.mp4');
    });

    test('multiple mixed items (photo + RAW + video) route to OpenBatch with all of them', () {
      final items = [
        _media('a.jpg', MediaFormat.jpeg),
        _media('b.dng', MediaFormat.dng),
        _media('c.mp4', MediaFormat.mp4),
      ];
      final decision = decideMediaRoute(items);
      expect(decision.route, isA<OpenBatch>());
      final batch = decision.route as OpenBatch;
      expect(batch.items.map((m) => m.path), ['a.jpg', 'b.dng', 'c.mp4']);
      expect(decision.unsupported, isEmpty);
    });

    test('two supported items of the same type also route to OpenBatch', () {
      final items = [
        _media('a.jpg', MediaFormat.jpeg),
        _media('b.jpg', MediaFormat.jpeg),
      ];
      final decision = decideMediaRoute(items);
      expect(decision.route, isA<OpenBatch>());
    });

    test('unsupported files are filtered out and reported, others still proceed', () {
      final items = [
        _media('a.jpg', MediaFormat.jpeg),
        _media('weird.xyz', MediaFormat.unknown),
      ];
      final decision = decideMediaRoute(items);
      // Only one supported item remains -> single-item editor, not batch.
      expect(decision.route, isA<OpenPhotoEditor>());
      expect(decision.unsupported, hasLength(1));
      expect(decision.unsupported.single.path, 'weird.xyz');
    });

    test('multiple unsupported files among several supported ones are all reported', () {
      final items = [
        _media('a.jpg', MediaFormat.jpeg),
        _media('b.mp4', MediaFormat.mp4),
        _media('bad1.xyz', MediaFormat.unknown),
        _media('bad2.xyz', MediaFormat.unknown),
      ];
      final decision = decideMediaRoute(items);
      expect(decision.route, isA<OpenBatch>());
      expect((decision.route as OpenBatch).items, hasLength(2));
      expect(decision.unsupported, hasLength(2));
    });

    test('every file unsupported routes to NothingToRoute, with every one reported', () {
      final items = [
        _media('bad1.xyz', MediaFormat.unknown),
        _media('bad2.xyz', MediaFormat.unknown),
      ];
      final decision = decideMediaRoute(items);
      expect(decision.route, isA<NothingToRoute>());
      expect(decision.unsupported, hasLength(2));
    });

    test('an empty selection routes to NothingToRoute with no errors', () {
      final decision = decideMediaRoute([]);
      expect(decision.route, isA<NothingToRoute>());
      expect(decision.unsupported, isEmpty);
    });
  });
}
