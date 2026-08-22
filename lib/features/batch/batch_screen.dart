import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/lut_asset.dart';
import '../../core/output_naming.dart';
import '../../theme/app_theme.dart';
import '../photo/photo_processor.dart';
import '../video/video_processor.dart';
import 'batch_controller.dart';
import 'batch_models.dart';

/// Multi-select batch flow: grades every picked photo/video with one shared
/// intensity and saves each straight into the dedicated gallery album as it
/// finishes. Cancellable between items; whatever has already saved stays
/// saved.
class BatchScreen extends StatefulWidget {
  final List<XFile> files;

  const BatchScreen({super.key, required this.files});

  @override
  State<BatchScreen> createState() => _BatchScreenState();
}

class _BatchScreenState extends State<BatchScreen> {
  late final BatchController _controller;
  double _intensity = 1.0;
  String? _cubeText;
  VideoGradeSession? _activeGradeSession;

  @override
  void initState() {
    super.initState();
    final items = widget.files.map(BatchItem.fromFile).toList();
    _controller = BatchController(
      items: items,
      processPhoto: _processPhoto,
      processVideo: _processVideo,
    )..addListener(_onControllerChanged);
  }

  void _onControllerChanged() => setState(() {});

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    // Best-effort: cancel any in-flight encode if the user backs out of
    // the batch screen entirely while a video is processing.
    _activeGradeSession?.cancel();
    super.dispose();
  }

  Future<void> _processPhoto(
    BatchItem item,
    double intensity,
    BatchProgressCallback onProgress,
  ) async {
    final cubeText = _cubeText ??= await loadAlexaLookLutText();
    onProgress(0.05);
    final bytes = await item.file.readAsBytes();
    onProgress(0.15);
    final prepared = await preparePhoto(
      PhotoPrepareRequest(
        originalBytes: bytes,
        cubeText: cubeText,
        // Batch only ever grades the full-resolution buffer — there's no
        // live slider preview here — so skip building the ~1200px preview
        // copy nobody looks at.
        buildPreview: false,
      ),
    );
    onProgress(0.4);
    final result = await gradeCachedPhoto(
      PhotoRegradeRequest.full(prepared, intensity),
    );
    onProgress(0.85);
    await Gal.putImageBytes(
      result.gradedBytes,
      album: kAlexaLookAlbum,
      name: generateUniqueOutputName(),
    );
    onProgress(1.0);
  }

  Future<void> _processVideo(
    BatchItem item,
    double intensity,
    BatchProgressCallback onProgress,
  ) async {
    // ffmpeg's lut3d filter bakes the look at full strength; blending it
    // toward the original at an arbitrary intensity would need a second
    // pass (blend filter) that isn't worth the extra encode time in a batch
    // run, so — same as the single-video editor — videos are always graded
    // at full look strength regardless of the shared intensity slider.
    final lutFile = await ensureAlexaLookLutFile();
    final session = await gradeVideoToTempFile(
      inputPath: item.file.path,
      lutPath: lutFile.path,
      onProgress: onProgress,
    );
    _activeGradeSession = session;
    final result = await session.result;
    _activeGradeSession = null;
    await Gal.putVideo(result.path, album: kAlexaLookAlbum);
    await deleteTempVideoBestEffort(result.path);
  }

  Future<void> _run() async {
    await _controller.run(_intensity);
    if (!mounted) return;
    if (_controller.failedCount == 0) {
      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved ${_controller.doneCount} item${_controller.doneCount == 1 ? '' : 's'} '
            'to $kAlexaLookAlbum album',
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${_controller.doneCount} saved, ${_controller.failedCount} failed. '
            'Tap a failed item to see why.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _controller.items;
    final photoCount = items.where((i) => i.type == BatchMediaType.photo).length;
    final videoCount = items.length - photoCount;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Batch'),
        actions: [
          if (_controller.isRunning)
            TextButton(
              onPressed: _controller.cancel,
              child: const Text('Cancel'),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Row(
              children: [
                Text(
                  '$photoCount photo${photoCount == 1 ? '' : 's'}, '
                  '$videoCount video${videoCount == 1 ? '' : 's'}',
                  style: const TextStyle(color: AppTheme.textSecondary),
                ),
                const Spacer(),
                Text(
                  '${_controller.doneCount}/${items.length} done',
                  style: const TextStyle(color: AppTheme.textSecondary),
                ),
              ],
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: items.length,
              itemBuilder: (context, index) => _BatchTile(item: items[index]),
            ),
          ),
          _buildControls(),
        ],
      ),
    );
  }

  Widget _buildControls() {
    final running = _controller.isRunning;
    final complete = _controller.isComplete;
    final items = _controller.items;
    final hasVideos = items.any((i) => i.type == BatchMediaType.video);
    final videosOnly = items.isNotEmpty && items.every((i) => i.type == BatchMediaType.video);
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
              Text('Intensity', style: Theme.of(context).textTheme.labelLarge),
              const Spacer(),
              Text(
                '${(_intensity * 100).round()}%',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: AppTheme.accent),
              ),
            ],
          ),
          Slider(
            value: _intensity,
            onChanged: running || videosOnly
                ? null
                : (v) => setState(() => _intensity = v),
          ),
          if (hasVideos)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Videos are always graded at 100%',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppTheme.textSecondary),
              ),
            ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: running || complete ? null : _run,
            icon: running
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.black),
                  )
                : const Icon(Icons.download_outlined),
            label: Text(
              complete
                  ? 'All done'
                  : running
                      ? 'Applying look & saving…'
                      : 'Apply look & save all',
            ),
          ),
        ],
      ),
    );
  }
}

class _BatchTile extends StatelessWidget {
  final BatchItem item;
  const _BatchTile({required this.item});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            color: AppTheme.surfaceHigh,
            child: item.type == BatchMediaType.photo
                ? Image.file(
                    File(item.file.path),
                    fit: BoxFit.cover,
                    cacheWidth: 240,
                    errorBuilder: (context, error, stack) => const Icon(
                      Icons.broken_image_outlined,
                      color: AppTheme.textSecondary,
                    ),
                  )
                : const _VideoPlaceholder(),
          ),
          _StatusOverlay(item: item),
        ],
      ),
    );
  }
}

class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Icon(Icons.videocam_outlined, color: AppTheme.textSecondary, size: 32),
    );
  }
}

class _StatusOverlay extends StatelessWidget {
  final BatchItem item;
  const _StatusOverlay({required this.item});

  @override
  Widget build(BuildContext context) {
    switch (item.status) {
      case BatchItemStatus.queued:
        return const SizedBox.shrink();
      case BatchItemStatus.processing:
        return Container(
          color: Colors.black.withValues(alpha: 0.45),
          child: Center(
            child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.6,
                value: item.progress > 0 ? item.progress : null,
                color: AppTheme.accent,
              ),
            ),
          ),
        );
      case BatchItemStatus.done:
        return Container(
          alignment: Alignment.topRight,
          padding: const EdgeInsets.all(4),
          child: const CircleAvatar(
            radius: 10,
            backgroundColor: AppTheme.accent,
            child: Icon(Icons.check, size: 14, color: Colors.black),
          ),
        );
      case BatchItemStatus.failed:
        return Material(
          color: Colors.black.withValues(alpha: 0.55),
          child: InkWell(
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(item.error ?? 'Failed to process this item.')),
              );
            },
            child: const Center(
              child: Icon(Icons.error_outline, color: Colors.redAccent, size: 26),
            ),
          ),
        );
    }
  }
}
