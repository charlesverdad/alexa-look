import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../theme/app_theme.dart';
import '../batch/batch_models.dart';
import '../batch/batch_screen.dart';
import '../photo/photo_screen.dart';
import '../video/video_screen.dart';

/// The app's entry screen: pick a photo, video, or multiple items to apply
/// the look to.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _pickingMedia = false;
  bool _pickingRaw = false;

  Future<void> _importRaw() async {
    if (_pickingRaw) return;
    setState(() => _pickingRaw = true);
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['dng', 'DNG'],
      );
      if (!mounted) return;
      final path = file?.path;
      if (path == null) return;
      await Navigator.of(context).push(
        AppTheme.route(PhotoScreen(initialRawPath: path)),
      );
    } finally {
      if (mounted) setState(() => _pickingRaw = false);
    }
  }

  Future<void> _selectMedia() async {
    if (_pickingMedia) return;
    setState(() => _pickingMedia = true);
    try {
      final picker = ImagePicker();
      final files = await picker.pickMultipleMedia();
      if (!mounted || files.isEmpty) return;

      if (files.length == 1) {
        // A single pick still gets the richer single-item editor, not the
        // grid-based batch flow.
        final file = files.first;
        final type = classifyMediaType(file);
        await Navigator.of(context).push(
          AppTheme.route(
            type == BatchMediaType.photo
                ? PhotoScreen(initialFile: file)
                : VideoScreen(initialFile: file),
          ),
        );
      } else {
        await Navigator.of(context).push(
          AppTheme.route(BatchScreen(files: files)),
        );
      }
    } finally {
      if (mounted) setState(() => _pickingMedia = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // A LayoutBuilder + SingleChildScrollView + a min-height ConstrainedBox
      // (rather than Spacers) centers this content on tall screens while
      // still scrolling instead of overflowing on short ones — needed now
      // that there are four action buttons plus the footer text.
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 48,
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
                    const SizedBox(height: 40),
                    _ActionButton(
                      icon: Icons.photo_outlined,
                      label: 'Photo',
                      subtitle: 'Grade a single photo, live preview as you adjust',
                      onTap: () => Navigator.of(context).push(
                        AppTheme.route(const PhotoScreen()),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _ActionButton(
                      icon: Icons.videocam_outlined,
                      label: 'Video',
                      subtitle: 'Grade a single video clip with ffmpeg',
                      onTap: () => Navigator.of(context).push(
                        AppTheme.route(const VideoScreen()),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _ActionButton(
                      icon: Icons.grid_view_outlined,
                      label: 'Batch',
                      subtitle: 'Select multiple photos & videos and grade them all at once',
                      busy: _pickingMedia,
                      onTap: _selectMedia,
                    ),
                    const SizedBox(height: 14),
                    _ActionButton(
                      icon: Icons.camera_outlined,
                      label: 'RAW',
                      subtitle: 'Import DNG (Xiaomi Pro mode)',
                      busy: _pickingRaw,
                      onTap: _importRaw,
                    ),
                    const SizedBox(height: 40),
                    Text(
                      'Original files are never modified.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.textSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '"ARRI" and "ALEXA" are trademarks of Arnold & Richter Cine '
                      'Technik GmbH & Co. KG. Alexa Look is an independent, '
                      'unaffiliated app.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.textSecondary.withValues(alpha: 0.7),
                          ),
                    ),
                    const SizedBox(height: 8),
                    // Open-source licenses used by the app, including the
                    // vendored LibRaw (RAW/DNG decoding) — see
                    // lib/core/licenses.dart.
                    Center(
                      child: TextButton(
                        onPressed: () => showLicensePage(
                          context: context,
                          applicationName: 'Alexa Look',
                        ),
                        child: Text(
                          'Licenses',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: AppTheme.textSecondary.withValues(alpha: 0.7),
                                decoration: TextDecoration.underline,
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
