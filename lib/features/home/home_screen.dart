import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../photo/photo_screen.dart';
import '../video/video_screen.dart';

/// The app's entry screen: pick a photo or a video to apply the look to.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 3),
              Text(
                'Alexa Look',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
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
              const Spacer(flex: 4),
              _ActionButton(
                icon: Icons.photo_outlined,
                label: 'Photo',
                subtitle: 'Grade a single photo',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PhotoScreen()),
                ),
              ),
              const SizedBox(height: 16),
              _ActionButton(
                icon: Icons.videocam_outlined,
                label: 'Video',
                subtitle: 'Grade a video clip',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const VideoScreen()),
                ),
              ),
              const Spacer(flex: 3),
              Text(
                '"ARRI" and "ALEXA" are trademarks of Arnold & Richter Cine '
                'Technik GmbH & Co. KG. Alexa Look is an independent, '
                'unaffiliated app.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.textSecondary.withValues(alpha: 0.7),
                    ),
              ),
              const SizedBox(height: 24),
            ],
          ),
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

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 22),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: AppTheme.surfaceHigh,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: AppTheme.accent, size: 26),
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
