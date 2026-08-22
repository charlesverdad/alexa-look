import 'package:flutter/foundation.dart';

import '../../core/cancellation.dart';
import 'batch_models.dart';

/// Reports progress (0..1) for one in-flight batch item.
typedef BatchProgressCallback = void Function(double progress);

/// Processes a single [BatchItem] at the given global [intensity], reporting
/// progress via [onProgress], and throws on failure. Saving (to the
/// dedicated album, with a unique name) is expected to happen inside this
/// callback — by the time it returns successfully the item is considered
/// saved.
typedef BatchItemProcessor = Future<void> Function(
  BatchItem item,
  double intensity,
  BatchProgressCallback onProgress,
);

/// Drives a list of [BatchItem]s through queued -> processing -> done (or
/// failed), one at a time, in order.
///
/// Pure state-machine logic with injectable processors so it is fully
/// testable without real image decoding or ffmpeg: a failure in one item's
/// processor never stops the run (failure isolation), and [cancel] stops the
/// run before the next queued item starts (already-processed items keep
/// whatever status — including `done`, i.e. already saved — they ended up
/// with).
class BatchController extends ChangeNotifier {
  final List<BatchItem> items;
  final BatchItemProcessor processPhoto;
  final BatchItemProcessor processRaw;
  final BatchItemProcessor processVideo;

  bool isRunning = false;
  bool _cancelRequested = false;

  BatchController({
    required this.items,
    required this.processPhoto,
    required this.processRaw,
    required this.processVideo,
  });

  /// True once every item has reached a terminal status (done, failed, or
  /// cancelled).
  bool get isComplete => items.every((i) =>
      i.status == BatchItemStatus.done ||
      i.status == BatchItemStatus.failed ||
      i.status == BatchItemStatus.cancelled);

  int get doneCount => items.where((i) => i.status == BatchItemStatus.done).length;
  int get failedCount => items.where((i) => i.status == BatchItemStatus.failed).length;
  int get cancelledCount => items.where((i) => i.status == BatchItemStatus.cancelled).length;

  /// Requests cancellation. Takes effect between items — the item currently
  /// processing (if any) is allowed to finish so its result is either fully
  /// saved or cleanly failed, never left half-written.
  void cancel() {
    _cancelRequested = true;
  }

  /// Runs every item that isn't already [BatchItemStatus.done], in list
  /// order, one at a time. Safe to call again after a cancellation to resume
  /// the remaining queued items.
  Future<void> run(double intensity) async {
    if (isRunning) return;
    isRunning = true;
    _cancelRequested = false;
    notifyListeners();

    for (final item in items) {
      if (_cancelRequested) break;
      if (item.status == BatchItemStatus.done) continue;

      item
        ..status = BatchItemStatus.processing
        ..progress = 0
        ..error = null;
      notifyListeners();

      try {
        final processor = switch (item.type) {
          BatchMediaType.photo => processPhoto,
          BatchMediaType.raw => processRaw,
          BatchMediaType.video => processVideo,
          BatchMediaType.unsupported => throw StateError(
              'BatchController received an unsupported item; unsupported '
              'items must be filtered out before a batch run is built.',
            ),
        };
        await processor(item, intensity, (p) {
          item.progress = p;
          notifyListeners();
        });
        item.status = BatchItemStatus.done;
        item.progress = 1;
      } on CancelledException {
        // A user-initiated cancellation (e.g. backing out of the batch
        // screen mid-encode) isn't a failure — nothing was saved for this
        // item, and there's nothing useful to report as an error.
        item.status = BatchItemStatus.cancelled;
        item.error = null;
      } catch (e) {
        item.status = BatchItemStatus.failed;
        item.error = e.toString();
      }
      notifyListeners();
    }

    isRunning = false;
    notifyListeners();
  }
}
