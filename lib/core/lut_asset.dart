import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// The bundled Alexa Look LUT asset path, as registered in pubspec.yaml.
const String alexaLookLutAssetPath = 'assets/luts/alexa_look_33.cube';

/// Loads the bundled Alexa Look `.cube` LUT as text, for use with
/// `CubeLut.parse` (photo pipeline, runs entirely in-process).
Future<String> loadAlexaLookLutText() {
  return rootBundle.loadString(alexaLookLutAssetPath);
}

/// Copies the bundled Alexa Look `.cube` LUT to a real file in the app's
/// documents directory, so external processes (ffmpeg) can reference it by
/// filesystem path. Reuses the existing copy if one is already there.
Future<File> ensureAlexaLookLutFile() async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/alexa_look_33.cube');
  if (!await file.exists()) {
    final bytes = await rootBundle.load(alexaLookLutAssetPath);
    await file.writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      flush: true,
    );
  }
  return file;
}
