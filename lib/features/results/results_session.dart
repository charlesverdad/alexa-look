/// Non-widget model behind [ResultsScreen] (see `results_screen.dart`): owns
/// the temp files backing a set of [ExportedItem]s until [dispose] is
/// called, and builds the plain path list `share_plus` needs for
/// "share all". Split out from the widget so this logic — items/their temp
/// files stay usable until dispose, share-all gathers every item's path —
/// is unit-testable without pumping a widget tree. See
/// `test/results_session_test.dart`.
library;

import 'dart:io';

import 'exported_item.dart';

Future<void> _defaultDeleteFile(String path) async {
  try {
    await File(path).delete();
  } catch (_) {
    // Best-effort cleanup — a results screen going away shouldn't surface a
    // failure to delete its own scratch temp files.
  }
}

class ResultsSession {
  final List<ExportedItem> items;
  final Future<void> Function(String path) deleteFile;
  bool _disposed = false;

  ResultsSession({
    required this.items,
    this.deleteFile = _defaultDeleteFile,
  });

  /// True once [dispose] has run — every item's temp file has been deleted
  /// (or attempted), and this session should no longer be used.
  bool get isDisposed => _disposed;

  /// The temp file paths for every item, in order — what `share_plus`
  /// needs (as `XFile`s, built by the widget layer) for a "Share all".
  /// Throws after [dispose]: sharing a file this session has already
  /// deleted would just fail confusingly at the OS share sheet instead.
  List<String> shareAllPaths() {
    if (_disposed) {
      throw StateError('Cannot share from a disposed ResultsSession.');
    }
    return items.map((item) => item.tempFilePath).toList();
  }

  /// Deletes every item's temp file. Idempotent — safe to call more than
  /// once (e.g. once from the widget's dispose() and, in a test, once more
  /// explicitly).
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final item in items) {
      await deleteFile(item.tempFilePath);
    }
  }
}
