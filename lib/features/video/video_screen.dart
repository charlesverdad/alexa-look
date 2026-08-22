import 'dart:async';

import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/return_code.dart';
import 'package:ffmpeg_kit_flutter_new_full/statistics.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/lut_asset.dart';
import '../../theme/app_theme.dart';

enum _Stage { picking, preparing, processing, done, error }

class VideoScreen extends StatefulWidget {
  const VideoScreen({super.key});

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  _Stage _stage = _Stage.picking;
  double _progress = 0;
  String? _errorMessage;
  String? _outputPath;
  int? _ffmpegSessionId;

  @override
  void initState() {
    super.initState();
    _pickAndProcess();
  }

  @override
  void dispose() {
    final id = _ffmpegSessionId;
    if (id != null) {
      FFmpegKit.cancel(id);
    }
    super.dispose();
  }

  Future<void> _pickAndProcess() async {
    try {
      final picker = ImagePicker();
      final file = await picker.pickVideo(source: ImageSource.gallery);
      if (file == null) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      setState(() => _stage = _Stage.preparing);
      await _process(file.path);
    } catch (e) {
      setState(() {
        _stage = _Stage.error;
        _errorMessage = 'Could not load that video: $e';
      });
    }
  }

  Future<void> _process(String inputPath) async {
    try {
      final lutFile = await ensureAlexaLookLutFile();
      final docsDir = await getApplicationDocumentsDirectory();
      final outputPath =
          '${docsDir.path}/alexa_look_${DateTime.now().millisecondsSinceEpoch}.mp4';

      // Ask ffprobe for the input duration so we can report real progress.
      double? durationSeconds;
      final probeSession = await FFprobeKit.getMediaInformation(inputPath);
      final info = probeSession.getMediaInformation();
      final durationStr = info?.getDuration();
      if (durationStr != null) {
        durationSeconds = double.tryParse(durationStr);
      }

      final lutPath = _escapeFfmpegFilterPath(lutFile.path);
      // mpeg4 + copy audio are both always available in the LGPL ffmpeg
      // build (no libx264/GPL codecs required).
      final command = "-y -i ${_quotePath(inputPath)} "
          "-vf lut3d=$lutPath "
          "-c:v mpeg4 -q:v 3 -c:a copy "
          "${_quotePath(outputPath)}";

      setState(() => _stage = _Stage.processing);

      final completer = Completer<void>();
      final session = await FFmpegKit.executeAsync(
        command,
        (session) async {
          final returnCode = await session.getReturnCode();
          if (!mounted) return;
          if (ReturnCode.isSuccess(returnCode)) {
            setState(() {
              _stage = _Stage.done;
              _outputPath = outputPath;
              _progress = 1;
            });
          } else {
            final logs = await session.getOutput();
            setState(() {
              _stage = _Stage.error;
              _errorMessage = 'ffmpeg failed (code $returnCode).\n${logs ?? ''}';
            });
          }
          if (!completer.isCompleted) completer.complete();
        },
        null,
        (Statistics stats) {
          if (!mounted || durationSeconds == null || durationSeconds == 0) {
            return;
          }
          final processedSeconds = stats.getTime() / 1000.0;
          final fraction = (processedSeconds / durationSeconds).clamp(0.0, 1.0);
          setState(() => _progress = fraction);
        },
      );
      _ffmpegSessionId = session.getSessionId();
      await completer.future;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _errorMessage = 'Could not process that video: $e';
      });
    }
  }

  Future<void> _save() async {
    final path = _outputPath;
    if (path == null) return;
    try {
      await Gal.putVideo(path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved to your gallery.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Video')),
      body: Center(
        child: switch (_stage) {
          _Stage.picking => const _StatusView(label: 'Opening picker…'),
          _Stage.preparing => const _StatusView(label: 'Preparing…'),
          _Stage.processing => _ProgressView(progress: _progress),
          _Stage.done => _DoneView(onSave: _save),
          _Stage.error => _ErrorView(message: _errorMessage ?? 'Something went wrong.'),
        },
      ),
    );
  }
}

/// Escapes a filesystem path for safe use as the `lut3d` filter's file
/// argument inside an ffmpeg filtergraph: backslashes and colons must be
/// escaped, and the whole path is then wrapped in single quotes to protect
/// any other filtergraph-special characters (commas, spaces, brackets).
String _escapeFfmpegFilterPath(String path) {
  final escaped = path
      .replaceAll('\\', '\\\\')
      .replaceAll(':', '\\:')
      .replaceAll("'", "\\'");
  return "'$escaped'";
}

/// Quotes a path for use as a plain ffmpeg command-line argument (input or
/// output file), so paths containing spaces survive ffmpeg's own argument
/// tokenizer.
String _quotePath(String path) => '"${path.replaceAll('"', '\\"')}"';

class _StatusView extends StatelessWidget {
  final String label;
  const _StatusView({required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(label, style: const TextStyle(color: AppTheme.textSecondary)),
      ],
    );
  }
}

class _ProgressView extends StatelessWidget {
  final double progress;
  const _ProgressView({required this.progress});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 72,
            height: 72,
            child: CircularProgressIndicator(
              value: progress > 0 ? progress : null,
              strokeWidth: 5,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Applying the look… ${(progress * 100).round()}%',
            style: const TextStyle(color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _DoneView extends StatelessWidget {
  final VoidCallback onSave;
  const _DoneView({required this.onSave});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check_circle_outline, color: AppTheme.accent, size: 48),
        const SizedBox(height: 16),
        const Text('Your graded video is ready.'),
        const SizedBox(height: 24),
        ElevatedButton.icon(
          onPressed: onSave,
          icon: const Icon(Icons.download_outlined),
          label: const Text('Save to gallery'),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  const _ErrorView({required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: AppTheme.textSecondary, size: 40),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
