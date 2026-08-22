import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/lut_asset.dart';
import '../../theme/app_theme.dart';
import 'photo_processor.dart';

enum _Stage { picking, processing, ready, saving, error }

class PhotoScreen extends StatefulWidget {
  const PhotoScreen({super.key});

  @override
  State<PhotoScreen> createState() => _PhotoScreenState();
}

class _PhotoScreenState extends State<PhotoScreen> {
  _Stage _stage = _Stage.picking;
  Uint8List? _originalBytes;
  Uint8List? _gradedBytes;
  double _pendingIntensity = 1.0;
  bool _showingOriginal = false;
  String? _errorMessage;
  String? _cubeText;

  @override
  void initState() {
    super.initState();
    _pickAndProcess();
  }

  Future<void> _pickAndProcess() async {
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(source: ImageSource.gallery);
      if (file == null) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      final bytes = await file.readAsBytes();
      _cubeText ??= await loadAlexaLookLutText();
      setState(() {
        _originalBytes = bytes;
        _stage = _Stage.processing;
      });
      await _regrade(1.0);
    } catch (e) {
      setState(() {
        _stage = _Stage.error;
        _errorMessage = 'Could not load that photo: $e';
      });
    }
  }

  Future<void> _regrade(double intensity) async {
    final original = _originalBytes;
    final cubeText = _cubeText;
    if (original == null || cubeText == null) return;
    setState(() => _stage = _Stage.processing);
    try {
      final result = await gradePhoto(
        PhotoGradeRequest(
          originalBytes: original,
          cubeText: cubeText,
          intensity: intensity,
        ),
      );
      if (!mounted) return;
      setState(() {
        _gradedBytes = result.gradedBytes;
        _stage = _Stage.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _errorMessage = 'Could not apply the look: $e';
      });
    }
  }

  Future<void> _save() async {
    final graded = _gradedBytes;
    if (graded == null) return;
    setState(() => _stage = _Stage.saving);
    try {
      await Gal.putImageBytes(graded, name: 'alexa_look_${DateTime.now().millisecondsSinceEpoch}');
      if (!mounted) return;
      setState(() => _stage = _Stage.ready);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved to your gallery.')),
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
    );
  }

  Widget _buildContent() {
    final original = _originalBytes;
    final graded = _gradedBytes;
    if (original == null) {
      return const _CenteredProgress(label: 'Loading…');
    }

    final bytesToShow = _showingOriginal || graded == null ? original : graded;
    final isBusy = _stage == _Stage.processing || _stage == _Stage.saving;

    return Column(
      children: [
        Expanded(
          child: Stack(
            alignment: Alignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.memory(
                    bytesToShow,
                    key: ValueKey(_showingOriginal),
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
              ),
              if (isBusy)
                Container(
                  color: Colors.black.withValues(alpha: 0.35),
                  child: const _CenteredProgress(label: 'Applying the look…'),
                ),
              Positioned(
                top: 24,
                right: 24,
                child: _BeforeAfterToggle(
                  showingOriginal: _showingOriginal,
                  onChanged: graded == null
                      ? null
                      : (v) => setState(() => _showingOriginal = v),
                ),
              ),
            ],
          ),
        ),
        _buildControls(isBusy: isBusy),
      ],
    );
  }

  Widget _buildControls({required bool isBusy}) {
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
            onChanged: isBusy
                ? null
                : (v) => setState(() => _pendingIntensity = v),
            onChangeEnd: isBusy ? null : (v) => _regrade(v),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: isBusy || _gradedBytes == null ? null : _save,
            icon: const Icon(Icons.download_outlined),
            label: const Text('Save to gallery'),
          ),
        ],
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
