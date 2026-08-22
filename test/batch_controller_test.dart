import 'package:flutter_test/flutter_test.dart';

import 'package:alexa_look/core/cancellation.dart';
import 'package:alexa_look/core/media_detector.dart';
import 'package:alexa_look/features/batch/batch_controller.dart';
import 'package:alexa_look/features/batch/batch_models.dart';

/// These tests are about BatchController's state machine, not
/// media_detector's content sniffing, so [type] just defaults from the
/// path's extension by the old familiar convention rather than actually
/// sniffing bytes.
BatchItem _item(String path, {BatchMediaType? type}) => BatchItem(
      id: path,
      path: path,
      type: type ?? (path.endsWith('.mp4') ? MediaCategory.video : MediaCategory.photo),
    );

/// A fake stand-in for [VideoGradeCancelledException] (video_processor.dart
/// isn't imported here to keep this a pure BatchController unit test) —
/// exercises the same `CancelledException` marker contract the real one
/// implements.
class _FakeCancelledException implements CancelledException {
  const _FakeCancelledException();
  @override
  String toString() => 'cancelled';
}

void main() {
  group('BatchController', () {
    test('runs every item queued -> processing -> done', () async {
      final items = [_item('a.jpg'), _item('b.jpg')];
      final seenStatusesById = <String, List<BatchItemStatus>>{
        for (final i in items) i.id: [i.status],
      };
      final controller = BatchController(
        items: items,
        processPhoto: (item, intensity, onProgress) async {
          onProgress(0.5);
          onProgress(1.0);
        },
        processRaw: (item, intensity, onProgress) async {},
        processVideo: (item, intensity, onProgress) async {},
      );
      controller.addListener(() {
        for (final i in items) {
          final list = seenStatusesById[i.id]!;
          if (list.isEmpty || list.last != i.status) list.add(i.status);
        }
      });

      await controller.run(1.0);

      expect(controller.isRunning, isFalse);
      expect(controller.isComplete, isTrue);
      expect(controller.doneCount, 2);
      expect(controller.failedCount, 0);
      for (final i in items) {
        expect(i.status, BatchItemStatus.done);
        expect(i.progress, 1.0);
        expect(
          seenStatusesById[i.id],
          [BatchItemStatus.queued, BatchItemStatus.processing, BatchItemStatus.done],
        );
      }
    });

    test('a failed item does not stop the rest of the batch (failure isolation)', () async {
      final items = [_item('bad.jpg'), _item('good.jpg'), _item('good2.jpg')];
      final controller = BatchController(
        items: items,
        processPhoto: (item, intensity, onProgress) async {
          if (item.id == 'bad.jpg') {
            throw Exception('decode failed');
          }
          onProgress(1.0);
        },
        processRaw: (item, intensity, onProgress) async {},
        processVideo: (item, intensity, onProgress) async {},
      );

      await controller.run(1.0);

      expect(items[0].status, BatchItemStatus.failed);
      expect(items[0].error, contains('decode failed'));
      expect(items[1].status, BatchItemStatus.done);
      expect(items[2].status, BatchItemStatus.done);
      expect(controller.doneCount, 2);
      expect(controller.failedCount, 1);
      expect(controller.isComplete, isTrue);
    });

    test('routes photos and videos to their respective processors', () async {
      final calledPhoto = <String>[];
      final calledVideo = <String>[];
      final items = [_item('a.jpg'), _item('b.mp4')];
      final controller = BatchController(
        items: items,
        processPhoto: (item, intensity, onProgress) async => calledPhoto.add(item.id),
        processRaw: (item, intensity, onProgress) async {},
        processVideo: (item, intensity, onProgress) async => calledVideo.add(item.id),
      );

      await controller.run(1.0);

      expect(calledPhoto, ['a.jpg']);
      expect(calledVideo, ['b.mp4']);
    });

    test('cancel() stops the run between items; already-done items stay done', () async {
      final items = [_item('a.jpg'), _item('b.jpg'), _item('c.jpg')];
      late BatchController controller;
      final processed = <String>[];
      controller = BatchController(
        items: items,
        processPhoto: (item, intensity, onProgress) async {
          processed.add(item.id);
          if (item.id == 'a.jpg') {
            // Simulate the user tapping "Cancel" mid-way through the first
            // item; it should still be allowed to finish and save.
            controller.cancel();
          }
        },
        processRaw: (item, intensity, onProgress) async {},
        processVideo: (item, intensity, onProgress) async {},
      );

      await controller.run(1.0);

      expect(processed, ['a.jpg']);
      expect(items[0].status, BatchItemStatus.done);
      expect(items[1].status, BatchItemStatus.queued);
      expect(items[2].status, BatchItemStatus.queued);
      expect(controller.isComplete, isFalse);
      expect(controller.isRunning, isFalse);

      // Calling run() again resumes the remaining queued items, and the
      // already-done first item is left untouched (not reprocessed).
      await controller.run(1.0);
      expect(processed, ['a.jpg', 'b.jpg', 'c.jpg']);
      expect(items.every((i) => i.status == BatchItemStatus.done), isTrue);
      expect(controller.isComplete, isTrue);
    });

    test('a CancelledException marks the item cancelled, not failed, and does not stop '
        'the rest of the batch', () async {
      final items = [_item('a.mp4'), _item('b.mp4'), _item('c.jpg')];
      final controller = BatchController(
        items: items,
        processPhoto: (item, intensity, onProgress) async => onProgress(1.0),
        processRaw: (item, intensity, onProgress) async {},
        processVideo: (item, intensity, onProgress) async {
          if (item.id == 'a.mp4') {
            throw const _FakeCancelledException();
          }
          onProgress(1.0);
        },
      );

      await controller.run(1.0);

      expect(items[0].status, BatchItemStatus.cancelled);
      expect(items[0].error, isNull);
      expect(items[1].status, BatchItemStatus.done);
      expect(items[2].status, BatchItemStatus.done);
      expect(controller.doneCount, 2);
      expect(controller.failedCount, 0);
      expect(controller.cancelledCount, 1);
      // A cancelled item is terminal, same as done/failed — it must not
      // block isComplete or leave the batch looking stuck.
      expect(controller.isComplete, isTrue);
    });

    test('calling cancel() while a video is mid-encode stops the batch: combined with '
        'the caller also cancelling the in-flight ffmpeg session (see BatchScreen.dispose), '
        'the item that was interrupted ends up cancelled and nothing further runs', () async {
      final items = [_item('a.mp4'), _item('b.mp4')];
      late BatchController controller;
      final started = <String>[];
      controller = BatchController(
        items: items,
        processPhoto: (item, intensity, onProgress) async {},
        processRaw: (item, intensity, onProgress) async {},
        processVideo: (item, intensity, onProgress) async {
          started.add(item.id);
          // Simulate BatchScreen.dispose(): the widget is torn down mid
          // encode, which calls both controller.cancel() (stop before the
          // next item) and the active VideoGradeSession's cancel() (stop
          // the current one) — the latter is what makes the video
          // processor's own future resolve with a CancelledException.
          controller.cancel();
          throw const _FakeCancelledException();
        },
      );

      await controller.run(1.0);

      expect(started, ['a.mp4']);
      expect(items[0].status, BatchItemStatus.cancelled);
      // cancel() took effect before the next item started.
      expect(items[1].status, BatchItemStatus.queued);
      expect(controller.isRunning, isFalse);
    });

    test('a second concurrent run() call is a no-op while one is in flight', () async {
      final items = [_item('a.jpg')];
      var startedCount = 0;
      final controller = BatchController(
        items: items,
        processPhoto: (item, intensity, onProgress) async {
          startedCount++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        },
        processRaw: (item, intensity, onProgress) async {},
        processVideo: (item, intensity, onProgress) async {},
      );

      final first = controller.run(1.0);
      final second = controller.run(1.0); // should return immediately, no-op
      await Future.wait([first, second]);

      expect(startedCount, 1);
      expect(items[0].status, BatchItemStatus.done);
    });

    test('routes a RAW item through processRaw, not processPhoto/processVideo', () async {
      final calledPhoto = <String>[];
      final calledRaw = <String>[];
      final calledVideo = <String>[];
      final items = [
        _item('a.jpg'),
        _item('b.dng', type: MediaCategory.raw),
        _item('c.mp4'),
      ];
      final controller = BatchController(
        items: items,
        processPhoto: (item, intensity, onProgress) async => calledPhoto.add(item.id),
        processRaw: (item, intensity, onProgress) async => calledRaw.add(item.id),
        processVideo: (item, intensity, onProgress) async => calledVideo.add(item.id),
      );

      await controller.run(1.0);

      expect(calledPhoto, ['a.jpg']);
      expect(calledRaw, ['b.dng']);
      expect(calledVideo, ['c.mp4']);
      expect(items.every((i) => i.status == BatchItemStatus.done), isTrue);
    });
  });
}
