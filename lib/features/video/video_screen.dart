import 'dart:async';

import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/lut_asset.dart';
import '../../core/output_naming.dart';
import '../../theme/app_theme.dart';
import 'video_processor.dart';

enum _Stage { picking, preparing, processing, done, error }

class VideoScreen extends StatefulWidget {
  /// When provided, this pre-picked file is graded directly instead of
  /// opening the picker again — used by the home screen's multi-select flow
  /// when exactly one video was chosen, so it still lands in this richer
  /// single-item editor.
  final XFile? initialFile;

  const VideoScreen({super.key, this.initialFile});

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
      XFile? file = widget.initialFile;
      if (file == null) {
        final picker = ImagePicker();
        file = await picker.pickVideo(source: ImageSource.gallery);
      }
      if (file == null) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      if (!mounted) return;
      setState(() => _stage = _Stage.preparing);
      await _process(file.path);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _errorMessage = 'Could not load that video: $e';
      });
    }
  }

  Future<void> _process(String inputPath) async {
    try {
      final lutFile = await ensureAlexaLookLutFile();

      if (!mounted) return;
      setState(() => _stage = _Stage.processing);

      final session = await gradeVideoToTempFile(
        inputPath: inputPath,
        lutPath: lutFile.path,
        onProgress: (fraction) {
          if (!mounted) return;
          setState(() => _progress = fraction);
        },
      );
      _ffmpegSessionId = session.sessionId;

      final outputPath = await session.outputPath;
      if (!mounted) return;
      setState(() {
        _stage = _Stage.done;
        _outputPath = outputPath;
        _progress = 1;
      });
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
    var didSave = false;
    try {
      await Gal.putVideo(path, album: kAlexaLookAlbum);
      didSave = true;
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved to $kAlexaLookAlbum album')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: $e')),
      );
    } finally {
      // The graded mp4 lives in the temp dir and is only needed until it's
      // been copied into the gallery — clean it up now so temp output
      // doesn't accumulate on disk.
      if (didSave) {
        await deleteTempVideoBestEffort(path);
      }
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
