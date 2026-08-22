import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/lut_asset.dart';
import '../../core/media_detector.dart';
import '../../core/media_routing.dart';
import '../../core/output_naming.dart';
import '../../theme/app_theme.dart';
import '../photo/photo_processor.dart';
import '../results/exported_item.dart';
import '../results/results_screen.dart';
import '../video/video_processor.dart';
import 'batch_controller.dart';
import 'batch_models.dart';
import 'batch_raw_processor.dart';

/// Multi-select batch flow: grades every picked photo/RAW/video with one
/// shared intensity and saves each straight into the dedicated gallery
/// album as it finishes. Cancellable between items; whatever has already
/// saved stays saved. Ends by showing the results screen for whatever was
/// exported (see `lib/features/results/results_screen.dart`), rather than
/// just a "saved" snackbar.
class BatchScreen extends StatefulWidget {
  final List<RoutableMedia> items;

  const BatchScreen({super.key, required this.items});

  @override
  State<BatchScreen> createState() => _BatchScreenState();
}

class _BatchScreenState extends State<BatchScreen> {
  late final BatchController _controller;
  double _intensity = 1.0;
  PreparedLut? _preparedLut;
  VideoGradeSession? _activeGradeSession;

  /// Populated as each item finishes saving, keyed by [BatchItem.id] —
  /// handed to the results screen once the run completes.
  final Map<String, ExportedItem> _exported = {};

  @override
  void initState() {
    super.initState();
    final items = widget.items.map((m) => BatchItem.fromRoutable(m)).toList();
    _controller = BatchController(
      items: items,
      processPhoto: _processPhoto,
      processRaw: _processRaw,
      processVideo: _processVideo,
    )..addListener(_onControllerChanged);
  }

  void _onControllerChanged() => setState(() {});

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    // Stop the batch run entirely if the user backs out of the batch screen:
    // tell the controller not to start any further queued items, and
    // best-effort cancel whichever ffmpeg encode is currently in flight (its
    // cancellation propagates out through the video processor as a distinct
    // "cancelled" outcome — see video_processor.dart — so the in-flight item
    // is marked cancelled rather than saved).
    _controller.cancel();
    _activeGradeSession?.cancel();
    unawaited(WakelockPlus.disable());
    super.dispose();
  }

  /// Shared tail of both the photo and RAW pipelines: save the graded JPEG
  /// bytes into the gallery album, and also stash a temp-file copy for the
  /// results screen to offer Share from (see `ExportedItem`).
  Future<void> _saveGradedPhoto(BatchItem item, Uint8List gradedBytes) async {
    final outputName = generateUniqueOutputName();
    await Gal.putImageBytes(gradedBytes, album: kAlexaLookAlbum, name: outputName);
    final tempDir = await getTemporaryDirectory();
    final tempPath = '${tempDir.path}/$outputName.jpg';
    await File(tempPath).writeAsBytes(gradedBytes, flush: true);
    _exported[item.id] = ExportedItem(
      id: item.id,
      kind: ExportedKind.photo,
      tempFilePath: tempPath,
      previewBytes: gradedBytes,
    );
  }

  Future<void> _processPhoto(
    BatchItem item,
    double intensity,
    BatchProgressCallback onProgress,
  ) async {
    // Parse the `.cube` LUT once for the whole batch and reuse the parsed
    // lattice for every item (photo and RAW alike) — CubeLut.parse is
    // wasted work to repeat per item when every item shares the same look.
    final preparedLut = _preparedLut ??= PreparedLut.parse(await loadAlexaLookLutText());
    onProgress(0.05);
    final bytes = await File(item.path).readAsBytes();
    onProgress(0.15);
    final prepared = await preparePhoto(
      PhotoPrepareRequest(
        originalBytes: bytes,
        preparedLut: preparedLut,
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
    await _saveGradedPhoto(item, result.gradedBytes);
    onProgress(1.0);
  }

  Future<void> _processRaw(
    BatchItem item,
    double intensity,
    BatchProgressCallback onProgress,
  ) async {
    final preparedLut = _preparedLut ??= PreparedLut.parse(await loadAlexaLookLutText());
    final gradedBytes = await gradeRawBatchItem(
      path: item.path,
      intensity: intensity,
      preparedLut: preparedLut,
      onProgress: onProgress,
    );
    await _saveGradedPhoto(item, gradedBytes);
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
      inputPath: item.path,
      lutPath: lutFile.path,
      onProgress: onProgress,
    );
    _activeGradeSession = session;
    try {
      final result = await session.result;
      await Gal.putVideo(result.path, album: kAlexaLookAlbum);
      // Unlike before, the temp mp4 is *not* deleted here — it's kept
      // around so the results screen can still offer Share while it's
      // open, and cleaned up when that screen is dismissed instead (see
      // ResultsSession.dispose).
      _exported[item.id] = ExportedItem(
        id: item.id,
        kind: ExportedKind.video,
        tempFilePath: result.path,
      );
    } finally {
      _activeGradeSession = null;
    }
  }

  Future<void> _run() async {
    // Prevent the screen from sleeping mid-batch — a batch run can take
    // minutes (several video encodes back to back), and losing the screen
    // shouldn't interrupt it. Cheap, no foreground-service machinery
    // required; see the README for the (deliberate) limits of this.
    await WakelockPlus.enable();
    try {
      await _controller.run(_intensity);
    } finally {
      unawaited(WakelockPlus.disable());
    }
    if (!mounted) return;

    final items = _controller.items;
    final exportedItems = [
      for (final item in items) ?_exported[item.id],
    ];

    String? summary;
    if (_controller.failedCount > 0 || _controller.cancelledCount > 0) {
      final parts = <String>[
        if (_controller.failedCount > 0) '${_controller.failedCount} failed',
        if (_controller.cancelledCount > 0) '${_controller.cancelledCount} cancelled',
      ];
      summary = parts.join(', ');
    }

    if (exportedItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(summary == null ? 'Nothing was saved.' : 'Nothing was saved — $summary.'),
        ),
      );
      return;
    }

    HapticFeedback.mediumImpact();
    await Navigator.of(context).push(
      AppTheme.route(ResultsScreen(items: exportedItems, summary: summary)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _controller.items;
    final photoCount = items.where((i) => i.type == MediaCategory.photo).length;
    final rawCount = items.where((i) => i.type == MediaCategory.raw).length;
    final videoCount = items.where((i) => i.type == MediaCategory.video).length;

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
                  _summaryLabel(photoCount: photoCount, rawCount: rawCount, videoCount: videoCount),
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

  String _summaryLabel({required int photoCount, required int rawCount, required int videoCount}) {
    final parts = <String>[
      if (photoCount > 0) '$photoCount photo${photoCount == 1 ? '' : 's'}',
      if (rawCount > 0) '$rawCount RAW',
      if (videoCount > 0) '$videoCount video${videoCount == 1 ? '' : 's'}',
    ];
    return parts.join(', ');
  }

  Widget _buildControls() {
    final running = _controller.isRunning;
    final complete = _controller.isComplete;
    final items = _controller.items;
    final hasVideos = items.any((i) => i.type == MediaCategory.video);
    final videosOnly = items.isNotEmpty && items.every((i) => i.type == MediaCategory.video);
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
            child: switch (item.type) {
              MediaCategory.photo => Image.file(
                  File(item.path),
                  fit: BoxFit.cover,
                  cacheWidth: 240,
                  errorBuilder: (context, error, stack) => const Icon(
                    Icons.broken_image_outlined,
                    color: AppTheme.textSecondary,
                  ),
                ),
              // A DNG's raw file bytes aren't directly displayable — showing
              // a placeholder icon here (rather than decoding an embedded
              // preview per grid tile) keeps the batch grid itself cheap;
              // the RAW decode chain still runs in full once this item is
              // actually processed.
              MediaCategory.raw => const _TypeIconPlaceholder(icon: Icons.camera_outlined),
              MediaCategory.video => const _TypeIconPlaceholder(icon: Icons.videocam_outlined),
              MediaCategory.unsupported =>
                const _TypeIconPlaceholder(icon: Icons.error_outline),
            },
          ),
          _StatusOverlay(item: item),
        ],
      ),
    );
  }
}

class _TypeIconPlaceholder extends StatelessWidget {
  final IconData icon;
  const _TypeIconPlaceholder({required this.icon});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(icon, color: AppTheme.textSecondary, size: 32),
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
      case BatchItemStatus.cancelled:
        return Container(
          color: Colors.black.withValues(alpha: 0.45),
          child: const Center(
            child: Icon(Icons.cancel_outlined, color: AppTheme.textSecondary, size: 26),
          ),
        );
    }
  }
}
