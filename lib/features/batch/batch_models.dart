import 'package:image_picker/image_picker.dart';

/// The two kinds of media the batch flow (and the single-item editors)
/// handle.
enum BatchMediaType { photo, video }

/// Video file extensions [image_picker]'s mixed image+video picker can hand
/// back, used to classify each picked [XFile] since `pickMultipleMedia`
/// returns a single untyped list. Not exhaustive of every video container in
/// existence, just the ones a phone gallery picker plausibly returns.
const Set<String> _videoExtensions = {
  'mp4', 'mov', 'm4v', 'avi', 'mkv', 'webm', '3gp', '3gpp',
};

/// Classifies [file] as a photo or video by its extension.
BatchMediaType classifyMediaType(XFile file) {
  final path = file.path;
  final dot = path.lastIndexOf('.');
  if (dot == -1 || dot == path.length - 1) return BatchMediaType.photo;
  final ext = path.substring(dot + 1).toLowerCase();
  return _videoExtensions.contains(ext) ? BatchMediaType.video : BatchMediaType.photo;
}

/// Where a single [BatchItem] is in the batch pipeline.
///
/// [cancelled] is terminal like [done]/[failed], but distinct from both: it
/// means processing was stopped by the user (e.g. backing out of the batch
/// screen mid-encode) rather than finishing successfully or erroring out —
/// nothing was saved for that item, and it isn't a failure to report.
enum BatchItemStatus { queued, processing, done, failed, cancelled }

/// One item in a batch run: a picked file, its classified media type, and
/// its current pipeline status/progress/error.
class BatchItem {
  final String id;
  final XFile file;
  final BatchMediaType type;
  BatchItemStatus status;
  double progress;
  String? error;

  BatchItem({
    required this.id,
    required this.file,
    required this.type,
    this.status = BatchItemStatus.queued,
    this.progress = 0,
    this.error,
  });

  factory BatchItem.fromFile(XFile file, {String? id}) {
    return BatchItem(
      id: id ?? '${file.path}#${identityHashCode(file)}',
      file: file,
      type: classifyMediaType(file),
    );
  }
}
