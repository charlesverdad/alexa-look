import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../../core/media_detector.dart';
import '../../core/media_routing.dart';
import '../../theme/app_theme.dart';
import '../batch/batch_screen.dart';
import '../photo/photo_screen.dart';
import '../video/video_screen.dart';
import 'about_sheet.dart';

/// File extensions offered by the "Browse files…" picker — anything the
/// mixed photo/video gallery picker can already surface plus formats it
/// typically can't (notably DNG). Case-insensitive: file_picker matches
/// extensions case-insensitively.
const List<String> kBrowsableFileExtensions = [
  'jpg', 'jpeg', 'png', 'heic', 'heif', 'webp', 'tiff', 'tif', 'dng',
  'mp4', 'mov', 'm4v', 'webm', 'mkv', 'avi',
];

/// The app's entry screen: one primary "Select media" action (mixed
/// photo+video, multi-select) plus a secondary "Browse files…" for anything
/// the gallery picker can't surface. What each selected file actually *is*
/// (photo, RAW, or video) is decided by content, not by which picker
/// produced it — see `lib/core/media_detector.dart` and
/// `lib/core/media_routing.dart` — and files shared into the app from
/// another app (Android only) flow through that exact same routing.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _busy = false;
  PackageInfo? _packageInfo;

  StreamSubscription<List<SharedMediaFile>>? _shareStreamSub;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPackageInfo());
    if (Platform.isAndroid) {
      unawaited(_handleInitialShare());
      _shareStreamSub = ReceiveSharingIntent.instance.getMediaStream().listen(
        (files) => unawaited(_handleSharedFiles(files)),
      );
    }
  }

  @override
  void dispose() {
    unawaited(_shareStreamSub?.cancel());
    super.dispose();
  }

  Future<void> _loadPackageInfo() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _packageInfo = info);
  }

  Future<void> _handleInitialShare() async {
    final files = await ReceiveSharingIntent.instance.getInitialMedia();
    await _handleSharedFiles(files);
  }

  Future<void> _handleSharedFiles(List<SharedMediaFile> files) async {
    if (files.isEmpty) return;
    // Consumed — don't hand the same shared files back on the next cold
    // start / stream listener attach.
    unawaited(ReceiveSharingIntent.instance.reset());
    if (!mounted) return;
    await _routePaths(files.map((f) => f.path).toList());
  }

  /// Classifies every path by content (see `classifyMediaFile`) and routes
  /// the result: a single supported item opens straight into its editor, an
  /// unsupported one is reported, and multiple supported items open the
  /// unified batch screen. Shared by the gallery picker, the file browser,
  /// and incoming share intents, so all three funnel through one decision.
  Future<void> _routePaths(List<String> paths) async {
    if (paths.isEmpty) return;
    final items = await Future.wait(paths.map((path) async {
      return RoutableMedia(path: path, detection: await classifyMediaFile(path));
    }));
    if (!mounted) return;

    final decision = decideMediaRoute(items);
    if (decision.unsupported.isNotEmpty) {
      final n = decision.unsupported.length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            n == 1
                ? "Couldn't use 1 file — unrecognized format."
                : "Couldn't use $n files — unrecognized format.",
          ),
        ),
      );
    }

    switch (decision.route) {
      case NothingToRoute():
        break;
      case OpenPhotoEditor(:final media):
        await Navigator.of(context).push(
          AppTheme.route(PhotoScreen(initialFile: XFile(media.path))),
        );
      case OpenRawEditor(:final media):
        await Navigator.of(context).push(
          AppTheme.route(PhotoScreen(initialRawPath: media.path)),
        );
      case OpenVideoEditor(:final media):
        await Navigator.of(context).push(
          AppTheme.route(VideoScreen(initialFile: XFile(media.path))),
        );
      case OpenBatch(:final items):
        await Navigator.of(context).push(
          AppTheme.route(BatchScreen(items: items)),
        );
    }
  }

  Future<void> _selectMedia() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final picker = ImagePicker();
      final files = await picker.pickMultipleMedia();
      if (!mounted) return;
      await _routePaths(files.map((f) => f.path).toList());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _browseFiles() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: kBrowsableFileExtensions,
        // ignore: deprecated_member_use
        allowMultiple: true,
      );
      if (!mounted) return;
      final paths = [for (final f in files) if (f.path != null) f.path!];
      await _routePaths(paths);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: (constraints.maxHeight - 48).clamp(0.0, double.infinity),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ShaderMask(
                      shaderCallback: (bounds) => const LinearGradient(
                        colors: [AppTheme.accent, AppTheme.textPrimary],
                      ).createShader(bounds),
                      child: Text(
                        'Alexa Look',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.displaySmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                              color: Colors.white,
                            ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'A gentle, filmic cinema look for your photos and videos.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: AppTheme.textSecondary,
                          ),
                    ),
                    const SizedBox(height: 48),
                    _ActionButton(
                      icon: Icons.add_photo_alternate_outlined,
                      label: 'Select media',
                      subtitle: 'Photos, RAW/DNG, and videos — pick one or many',
                      busy: _busy,
                      onTap: _selectMedia,
                    ),
                    const SizedBox(height: 14),
                    Center(
                      child: TextButton.icon(
                        onPressed: _busy ? null : _browseFiles,
                        icon: const Icon(Icons.folder_open_outlined, size: 18),
                        label: const Text('Browse files…'),
                      ),
                    ),
                    const SizedBox(height: 40),
                    Center(
                      child: TextButton(
                        onPressed: () => showAboutSheet(context, _packageInfo),
                        child: Text(
                          _packageInfo == null ? ' ' : 'v${_packageInfo!.version}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: AppTheme.textSecondary.withValues(alpha: 0.6),
                              ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;
  final bool busy;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 22),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: AppTheme.surfaceHigh,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: busy
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : Icon(icon, color: AppTheme.accent, size: 26),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.textSecondary,
                          ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppTheme.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}
