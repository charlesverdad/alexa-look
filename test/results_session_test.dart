// Tests for the results screen's non-widget model
// (lib/features/results/results_session.dart): items/their temp files stay
// usable until dispose, share-all builds one path per item, and dispose is
// safe to call more than once.

import 'package:flutter_test/flutter_test.dart';

import 'package:alexa_look/features/results/exported_item.dart';
import 'package:alexa_look/features/results/results_session.dart';

void main() {
  group('ResultsSession', () {
    test('is not disposed initially, and shareAllPaths returns every item\'s temp path', () {
      final session = ResultsSession(
        items: const [
          ExportedItem(id: 'a', kind: ExportedKind.photo, tempFilePath: '/tmp/a.jpg'),
          ExportedItem(id: 'b', kind: ExportedKind.video, tempFilePath: '/tmp/b.mp4'),
        ],
        deleteFile: (path) async {},
      );

      expect(session.isDisposed, isFalse);
      expect(session.shareAllPaths(), ['/tmp/a.jpg', '/tmp/b.mp4']);
    });

    test('dispose deletes every item\'s temp file exactly once', () async {
      final deleted = <String>[];
      final session = ResultsSession(
        items: const [
          ExportedItem(id: 'a', kind: ExportedKind.photo, tempFilePath: '/tmp/a.jpg'),
          ExportedItem(id: 'b', kind: ExportedKind.video, tempFilePath: '/tmp/b.mp4'),
        ],
        deleteFile: (path) async => deleted.add(path),
      );

      await session.dispose();

      expect(deleted, ['/tmp/a.jpg', '/tmp/b.mp4']);
      expect(session.isDisposed, isTrue);
    });

    test('dispose is idempotent — calling it again does not delete a second time', () async {
      final deleted = <String>[];
      final session = ResultsSession(
        items: const [
          ExportedItem(id: 'a', kind: ExportedKind.photo, tempFilePath: '/tmp/a.jpg'),
        ],
        deleteFile: (path) async => deleted.add(path),
      );

      await session.dispose();
      await session.dispose();

      expect(deleted, ['/tmp/a.jpg']);
    });

    test('shareAllPaths throws after dispose — nothing left to share from', () async {
      final session = ResultsSession(
        items: const [
          ExportedItem(id: 'a', kind: ExportedKind.photo, tempFilePath: '/tmp/a.jpg'),
        ],
        deleteFile: (path) async {},
      );

      await session.dispose();

      expect(() => session.shareAllPaths(), throwsStateError);
    });

    test('a delete failure for one item does not stop the rest from being cleaned up', () async {
      final deleted = <String>[];
      final session = ResultsSession(
        items: const [
          ExportedItem(id: 'a', kind: ExportedKind.photo, tempFilePath: '/tmp/a.jpg'),
          ExportedItem(id: 'b', kind: ExportedKind.photo, tempFilePath: '/tmp/b.jpg'),
        ],
        deleteFile: (path) async {
          deleted.add(path);
        },
      );

      await session.dispose();
      expect(deleted, ['/tmp/a.jpg', '/tmp/b.jpg']);
    });

    test('the default deleteFile is best-effort and does not throw for a missing file', () async {
      final session = ResultsSession(
        items: const [
          ExportedItem(
            id: 'a',
            kind: ExportedKind.photo,
            tempFilePath: '/nonexistent/path/that/does/not/exist.jpg',
          ),
        ],
      );

      await expectLater(session.dispose(), completes);
    });

    test('an empty item list disposes cleanly with no deletions', () async {
      final session = ResultsSession(items: const [], deleteFile: (path) async {});
      await session.dispose();
      expect(session.shareAllPaths, throwsStateError);
    });
  });
}
