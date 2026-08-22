/// The results screen shown after a batch run completes, or after a
/// single photo/video save — replaces the old "Saved to album" snackbar-only
/// UX with a grid of what was exported this session: tap a photo for a
/// full-screen preview, tap a video for Share, and a per-item or
/// "Share all" share action via `share_plus`.
///
/// Every item's temp file is owned by this screen's [ResultsSession] for as
/// long as this screen exists — see `results_session.dart` — and deleted on
/// dispose. The permanent saved copy already lives in the device's Alexa
/// Look gallery album regardless of what happens to that temp file.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/output_naming.dart';
import '../../theme/app_theme.dart';
import 'exported_item.dart';
import 'results_session.dart';

class ResultsScreen extends StatefulWidget {
  final List<ExportedItem> items;

  /// An optional extra status line shown under the "Saved to album"
  /// subtitle — e.g. "1 failed, 1 cancelled" for a batch run that didn't
  /// fully succeed. `null` when everything in [items] is all there is to
  /// say.
  final String? summary;

  const ResultsScreen({super.key, required this.items, this.summary});

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  late final ResultsSession _session;

  @override
  void initState() {
    super.initState();
    _session = ResultsSession(items: widget.items);
  }

  @override
  void dispose() {
    // Fire-and-forget: this screen is going away regardless, and cleanup
    // failures are already swallowed inside ResultsSession.dispose.
    unawaited(_session.dispose());
    super.dispose();
  }

  Future<void> _share(ExportedItem item) {
    return SharePlus.instance.share(
      ShareParams(files: [XFile(item.tempFilePath)]),
    );
  }

  Future<void> _shareAll() {
    final paths = _session.shareAllPaths();
    return SharePlus.instance.share(
      ShareParams(
        files: [for (final p in paths) XFile(p)],
        subject: 'Alexa Look',
      ),
    );
  }

  void _open(ExportedItem item) {
    if (item.kind == ExportedKind.photo && item.previewBytes != null) {
      Navigator.of(context).push(
        AppTheme.route(_PhotoPreview(item: item, onShare: () => _share(item))),
      );
    } else {
      _showVideoActions(item);
    }
  }

  void _showVideoActions(ExportedItem item) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.ios_share, color: AppTheme.accent),
              title: const Text('Share video'),
              onTap: () {
                Navigator.pop(sheetContext);
                unawaited(_share(item));
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Results'),
        actions: [
          if (items.length > 1)
            TextButton.icon(
              onPressed: _shareAll,
              icon: const Icon(Icons.ios_share, size: 18),
              label: const Text('Share all'),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Saved ${items.length} item${items.length == 1 ? '' : 's'} '
                  'to $kAlexaLookAlbum album',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (widget.summary != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    widget.summary!,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppTheme.textSecondary),
                  ),
                ],
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
              itemBuilder: (context, index) {
                final item = items[index];
                return _ResultTile(
                  item: item,
                  onTap: () => _open(item),
                  onShare: () => _share(item),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultTile extends StatelessWidget {
  final ExportedItem item;
  final VoidCallback onTap;
  final VoidCallback onShare;

  const _ResultTile({required this.item, required this.onTap, required this.onShare});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surfaceHigh,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (item.kind == ExportedKind.photo && item.previewBytes != null)
              Image.memory(item.previewBytes!, fit: BoxFit.cover)
            else
              const Center(
                child: Icon(Icons.play_circle_outline, color: AppTheme.textSecondary, size: 32),
              ),
            Positioned(
              top: 4,
              right: 4,
              child: Material(
                color: Colors.black.withValues(alpha: 0.55),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onShare,
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(Icons.ios_share, color: Colors.white, size: 16),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhotoPreview extends StatelessWidget {
  final ExportedItem item;
  final VoidCallback onShare;

  const _PhotoPreview({required this.item, required this.onShare});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        actions: [
          IconButton(onPressed: onShare, icon: const Icon(Icons.ios_share)),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 5,
          child: Image.memory(item.previewBytes!, fit: BoxFit.contain),
        ),
      ),
    );
  }
}
