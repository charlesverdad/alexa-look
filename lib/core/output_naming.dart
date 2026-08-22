/// Output naming and gallery-album conventions shared by the photo, video,
/// and batch save paths, so every save follows the same rules: a dedicated
/// gallery album, and a collision-free unique name per output (originals are
/// never touched, and outputs never overwrite each other or anything else).
library;

import 'package:uuid/uuid.dart';

/// The dedicated gallery album every graded photo/video is saved into.
/// Never the camera roll / default album — see the app's "never overwrite,
/// always a dedicated album" guarantee.
const String kAlexaLookAlbum = 'Alexa Look';

const _uuid = Uuid();

String _two(int n) => n.toString().padLeft(2, '0');

/// Formats [dt] as `yyyyMMdd_HHmmss`.
String formatTimestampForFilename(DateTime dt) {
  return '${dt.year.toString().padLeft(4, '0')}${_two(dt.month)}${_two(dt.day)}'
      '_${_two(dt.hour)}${_two(dt.minute)}${_two(dt.second)}';
}

/// Generates a unique output base name of the form
/// `alexa_look_<yyyyMMdd_HHmmss>_<8-char-uuid-suffix>`, guaranteed
/// collision-free even across many items generated within the same second
/// (e.g. a batch save) thanks to the random UUID suffix. Contains no file
/// extension — callers append one if their sink requires it.
String generateUniqueOutputName({DateTime? now}) {
  final stamp = formatTimestampForFilename(now ?? DateTime.now());
  final suffix = _uuid.v4().replaceAll('-', '').substring(0, 8);
  return 'alexa_look_${stamp}_$suffix';
}
