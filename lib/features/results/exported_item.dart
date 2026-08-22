/// What kind of output an [ExportedItem] holds — governs how the results
/// screen previews and opens it.
library;

import 'dart:typed_data';

enum ExportedKind { photo, video }

/// One graded output produced this session — by the single-photo editor,
/// the single-video editor, or one item of a batch run — kept in memory
/// (photo bytes) and/or on disk (a temp file, for both photo and video)
/// only for as long as the results screen showing it is open. The *real*
/// saved copy already lives in the device's Alexa Look gallery album by the
/// time an [ExportedItem] exists; [tempFilePath] exists purely to make
/// `share_plus` sharing possible while the results screen is up (see
/// `lib/features/results/results_session.dart`).
class ExportedItem {
  final String id;
  final ExportedKind kind;

  /// Temp file holding this item's exported bytes — a JPEG for a photo, the
  /// already-graded mp4 for a video. Deleted when the results screen
  /// displaying this item is disposed (see `ResultsSession.dispose`).
  final String tempFilePath;

  /// In-memory bytes for a photo — used for the grid thumbnail and the
  /// full-screen `InteractiveViewer` preview. `null` for a video: video
  /// tiles show a play icon and are previewed/opened via [tempFilePath]
  /// instead, so this never needs a video-thumbnail decode (and doesn't
  /// pull in a video-processing dependency just for that).
  final Uint8List? previewBytes;

  const ExportedItem({
    required this.id,
    required this.kind,
    required this.tempFilePath,
    this.previewBytes,
  });
}
