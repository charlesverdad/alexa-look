import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/lut_asset.dart';
import '../../core/output_naming.dart';
import '../../theme/app_theme.dart';
import '../results/exported_item.dart';
import '../results/results_screen.dart';
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
  VideoEncoder? _encoderUsed;
  VideoGradeSession? _gradeSession;

  /// Created before any of [_process]'s awaits, same reasoning as
  /// `BatchScreen._activeCancellationToken`: it exists (and so can be
  /// cancelled) even while grading is still in ffprobe/startup, before
  /// [_gradeSession] itself has been assigned.
  VideoCancellationToken? _cancellationToken;

  /// True once this screen's [Gal.putVideo] save has succeeded. The temp
  /// mp4 [_outputPath] points at is only guaranteed to exist until the
  /// results screen pushed from [_save] is dismissed (see
  /// `ResultsSession.dispose`), so a second tap of Save after that would
  /// fail with nothing to recover — this instead disables Save once it's
  /// already succeeded, see [_DoneView].
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _pickAndProcess();
  }

  @override
  void dispose() {
    _cancellationToken?.cancel();
    _gradeSession?.cancel();
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
      final token = VideoCancellationToken();
      _cancellationToken = token;
      final lutFile = await ensureAlexaLookLutFile();

      if (!mounted) return;
      setState(() => _stage = _Stage.processing);

      final session = await gradeVideoToTempFile(
        inputPath: inputPath,
        lutPath: lutFile.path,
        cancellationToken: token,
        onProgress: (fraction) {
          if (!mounted) return;
          setState(() => _progress = fraction);
        },
      );
      _gradeSession = session;

      final result = await session.result;
      if (!mounted) return;
      setState(() {
        _stage = _Stage.done;
        _outputPath = result.path;
        _encoderUsed = result.encoder;
        _progress = 1;
      });
    } on VideoGradeCancelledException {
      // The user backed out of this screen while grading was in flight (see
      // dispose()), which cancelled the in-flight ffmpeg attempt. Stop
      // silently — there's nothing to save and, since the widget is already
      // unmounted by the time this resolves, nothing to show either.
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
    // Already saved once — the temp file at `path` only survives until the
    // results screen pushed below is dismissed (ResultsSession.dispose
    // deletes it), so a second Save tap after that would have nothing left
    // to copy. The Save button is disabled once _saved is true (see
    // VideoDoneView), so this is just defense in depth.
    if (path == null || _saved) return;
    try {
      await Gal.putVideo(path, album: kAlexaLookAlbum);
      if (!mounted) return;
      setState(() => _saved = true);
      HapticFeedback.mediumImpact();
      // The graded mp4 already lives in the temp dir — keep it there
      // (rather than deleting it now that it's copied into the gallery) so
      // the results screen can still offer Share while it's open. It's
      // deleted when that screen is dismissed instead, see
      // ResultsSession.dispose.
      await Navigator.of(context).push(
        AppTheme.route(
          ResultsScreen(
            items: [
              ExportedItem(
                id: generateUniqueOutputName(),
                kind: ExportedKind.video,
                tempFilePath: path,
              ),
            ],
            summary: _encoderUsed == null ? null : 'Encoded with ${_encoderUsed!.label}',
          ),
        ),
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
          _Stage.done => VideoDoneView(onSave: _save, saved: _saved),
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

/// The "done" stage's body: a Save button that becomes a disabled "Saved"
/// state once [saved] is true, rather than staying tappable and failing the
/// second time (see `_VideoScreenState._save`, which is the only real
/// caller — this is a top-level, non-private widget purely so it can be
/// pumped directly in widget tests without needing to drive the whole
/// picker/ffmpeg flow that gets a `VideoScreen` into this stage).
class VideoDoneView extends StatelessWidget {
  final VoidCallback onSave;
  final bool saved;
  const VideoDoneView({super.key, required this.onSave, this.saved = false});

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
          onPressed: saved ? null : onSave,
          icon: Icon(saved ? Icons.check : Icons.download_outlined),
          label: Text(saved ? 'Saved to gallery' : 'Save to gallery'),
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
