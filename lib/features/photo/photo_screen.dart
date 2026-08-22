import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/lut_asset.dart';
import '../../core/output_naming.dart';
import '../../theme/app_theme.dart';
import 'photo_processor.dart';

enum _Stage { picking, processing, ready, saving, error }

class PhotoScreen extends StatefulWidget {
  /// When provided, this pre-picked file is graded directly instead of
  /// opening the picker again — used by the home screen's multi-select flow
  /// when exactly one photo was chosen, so it still lands in this richer
  /// single-item editor.
  final XFile? initialFile;

  const PhotoScreen({super.key, this.initialFile});

  @override
  State<PhotoScreen> createState() => _PhotoScreenState();
}

class _PhotoScreenState extends State<PhotoScreen> {
  _Stage _stage = _Stage.picking;
  Uint8List? _originalBytes;
  Uint8List? _previewBytes;
  double _pendingIntensity = 1.0;
  bool _toggledOriginal = false;
  bool _holdingOriginal = false;
  String? _errorMessage;
  String? _cubeText;

  // Cached after the first prepare so that dragging the intensity slider
  // only re-runs the cheap LUT-apply + encode step on the small preview
  // buffer, not decode/resize/LUT-parse or full-resolution work.
  PreparedPhoto? _prepared;

  // Live-preview regrade throttling: at most one preview grade in flight at
  // a time; if the slider moves again while one is running, only the latest
  // requested intensity is kept and graded next ("latest wins").
  bool _previewGrading = false;
  double? _queuedPreviewIntensity;

  @override
  void initState() {
    super.initState();
    _pickAndProcess();
  }

  Future<void> _pickAndProcess() async {
    try {
      XFile? file = widget.initialFile;
      if (file == null) {
        final picker = ImagePicker();
        file = await picker.pickImage(source: ImageSource.gallery);
      }
      if (file == null) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      final bytes = await file.readAsBytes();
      final cubeText = _cubeText ??= await loadAlexaLookLutText();
      if (!mounted) return;
      setState(() {
        _originalBytes = bytes;
        _stage = _Stage.processing;
      });
      final prepared = await preparePhoto(
        PhotoPrepareRequest(originalBytes: bytes, cubeText: cubeText),
      );
      if (!mounted) return;
      _prepared = prepared;
      setState(() => _stage = _Stage.ready);
      unawaited(_requestPreviewGrade(_pendingIntensity));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _errorMessage = 'Could not load that photo: $e';
      });
    }
  }

  /// Requests a live preview regrade at [intensity]. Cheap and near-instant
  /// (operates on the small downscaled preview buffer): safe to call on
  /// every slider tick. At most one grade runs at a time; if one is already
  /// in flight, [intensity] just replaces whatever was queued, and the
  /// in-flight grade's completion picks it up next — the slider never falls
  /// behind a backlog of stale requests.
  Future<void> _requestPreviewGrade(double intensity) async {
    _queuedPreviewIntensity = intensity;
    if (_previewGrading) return;
    _previewGrading = true;
    while (_queuedPreviewIntensity != null) {
      final target = _queuedPreviewIntensity!;
      _queuedPreviewIntensity = null;
      final prepared = _prepared;
      if (prepared == null) break;
      try {
        final result = await gradeCachedPhoto(
          PhotoRegradeRequest.preview(prepared, target),
        );
        if (!mounted) break;
        setState(() => _previewBytes = result.gradedBytes);
      } catch (_) {
        // Keep showing the last good preview; a transient preview failure
        // isn't worth interrupting the user with — saving will surface any
        // real problem.
      }
    }
    _previewGrading = false;
  }

  Future<void> _save() async {
    final prepared = _prepared;
    if (prepared == null) return;
    setState(() => _stage = _Stage.saving);
    try {
      final result = await gradeCachedPhoto(
        PhotoRegradeRequest.full(prepared, _pendingIntensity),
      );
      await Gal.putImageBytes(
        result.gradedBytes,
        album: kAlexaLookAlbum,
        name: generateUniqueOutputName(),
      );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() => _stage = _Stage.ready);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved to $kAlexaLookAlbum album')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _stage = _Stage.ready);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Photo')),
      body: switch (_stage) {
        _Stage.picking => const _CenteredProgress(label: 'Opening picker…'),
        _Stage.error => _ErrorView(message: _errorMessage ?? 'Something went wrong.'),
        _ => _buildContent(),
      },
      floatingActionButton: _stage == _Stage.error || _originalBytes == null
          ? null
          : _SaveFab(
              saving: _stage == _Stage.saving,
              enabled: _stage != _Stage.saving && _prepared != null,
              onPressed: _save,
            ),
    );
  }

  Widget _buildContent() {
    final original = _originalBytes;
    final preview = _previewBytes;
    if (original == null) {
      return const _CenteredProgress(label: 'Loading…');
    }

    final showOriginal = _toggledOriginal || _holdingOriginal || preview == null;
    final bytesToShow = showOriginal ? original : preview;
    final isSaving = _stage == _Stage.saving;

    return Column(
      children: [
        Expanded(
          child: Stack(
            alignment: Alignment.center,
            children: [
              GestureDetector(
                onLongPressStart: (_) => setState(() => _holdingOriginal = true),
                onLongPressEnd: (_) => setState(() => _holdingOriginal = false),
                onLongPressCancel: () => setState(() => _holdingOriginal = false),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.memory(
                      bytesToShow,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
              ),
              if (_previewGrading && !showOriginal)
                const Positioned(
                  bottom: 16,
                  child: _SubtleBusyChip(label: 'Updating preview…'),
                ),
              if (isSaving)
                Container(
                  color: Colors.black.withValues(alpha: 0.45),
                  child: const _CenteredProgress(label: 'Applying the full-quality look…'),
                ),
              Positioned(
                top: 24,
                right: 24,
                child: _BeforeAfterToggle(
                  showingOriginal: _toggledOriginal,
                  onChanged: preview == null
                      ? null
                      : (v) => setState(() => _toggledOriginal = v),
                ),
              ),
              const Positioned(
                bottom: 8,
                left: 0,
                right: 0,
                child: _HoldHint(),
              ),
            ],
          ),
        ),
        _buildControls(isSaving: isSaving),
      ],
    );
  }

  Widget _buildControls({required bool isSaving}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'Intensity',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const Spacer(),
              Text(
                '${(_pendingIntensity * 100).round()}%',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: AppTheme.accent),
              ),
            ],
          ),
          Slider(
            value: _pendingIntensity,
            onChanged: isSaving || _prepared == null
                ? null
                : (v) {
                    setState(() => _pendingIntensity = v);
                    unawaited(_requestPreviewGrade(v));
                  },
          ),
          const SizedBox(height: 60),
        ],
      ),
    );
  }
}

class _SaveFab extends StatelessWidget {
  final bool saving;
  final bool enabled;
  final VoidCallback onPressed;

  const _SaveFab({required this.saving, required this.enabled, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      onPressed: enabled ? onPressed : null,
      backgroundColor: enabled ? AppTheme.accent : AppTheme.surfaceHigh,
      foregroundColor: Colors.black,
      icon: saving
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.black),
            )
          : const Icon(Icons.download_outlined),
      label: Text(saving ? 'Saving…' : 'Save'),
    );
  }
}

class _HoldHint extends StatelessWidget {
  const _HoldHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'Press and hold to compare',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppTheme.textSecondary.withValues(alpha: 0.8),
            ),
      ),
    );
  }
}

class _SubtleBusyChip extends StatelessWidget {
  final String label;
  const _SubtleBusyChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accent),
            ),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _BeforeAfterToggle extends StatelessWidget {
  final bool showingOriginal;
  final ValueChanged<bool>? onChanged;

  const _BeforeAfterToggle({required this.showingOriginal, this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onChanged == null ? null : () => onChanged!(!showingOriginal),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            showingOriginal ? 'Before' : 'After',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _CenteredProgress extends StatelessWidget {
  final String label;
  const _CenteredProgress({required this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(label, style: const TextStyle(color: AppTheme.textSecondary)),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  const _ErrorView({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppTheme.textSecondary, size: 40),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
