import '../../core/media_detector.dart';
import '../../core/media_routing.dart';

/// The three kinds of media the batch flow (and the single-item editors)
/// handle. Batch item classification is content-based (see
/// `lib/core/media_detector.dart`), so this is just [MediaCategory] under a
/// name local to the batch feature — [MediaCategory.unsupported] never
/// appears on a real [BatchItem]: unsupported files are filtered out by
/// `decideMediaRoute` before a batch is ever opened.
typedef BatchMediaType = MediaCategory;

/// Where a single [BatchItem] is in the batch pipeline.
///
/// [cancelled] is terminal like [done]/[failed], but distinct from both: it
/// means processing was stopped by the user (e.g. backing out of the batch
/// screen mid-encode) rather than finishing successfully or erroring out —
/// nothing was saved for that item, and it isn't a failure to report.
enum BatchItemStatus { queued, processing, done, failed, cancelled }

/// One item in a batch run: a picked file's path, its content-classified
/// media type, and its current pipeline status/progress/error.
class BatchItem {
  final String id;
  final String path;
  final BatchMediaType type;
  BatchItemStatus status;
  double progress;
  String? error;

  BatchItem({
    required this.id,
    required this.path,
    required this.type,
    this.status = BatchItemStatus.queued,
    this.progress = 0,
    this.error,
  });

  factory BatchItem.fromRoutable(RoutableMedia media, {String? id}) {
    return BatchItem(
      id: id ?? '${media.path}#${identityHashCode(media)}',
      path: media.path,
      type: media.detection.category,
    );
  }
}
