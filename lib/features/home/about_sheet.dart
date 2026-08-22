/// The About sheet tucked behind the version number at the bottom of the
/// home screen — app identity, the "never modifies originals" promise, the
/// ARRI trademark note, and a way into the open-source licenses page
/// (previously all shown directly on the home screen; now one tap away to
/// keep the home screen itself uncluttered).
library;

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../theme/app_theme.dart';

void showAboutSheet(BuildContext context, PackageInfo? packageInfo) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppTheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Alexa Look',
              style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              packageInfo == null
                  ? ' '
                  : 'Version ${packageInfo.version} (${packageInfo.buildNumber})',
              style: Theme.of(sheetContext)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 20),
            Text(
              'Originals are never modified — output goes to the Alexa Look album.',
              style: Theme.of(sheetContext).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Text(
              '"ARRI" and "ALEXA" are trademarks of Arnold & Richter Cine '
              'Technik GmbH & Co. KG. Alexa Look is an independent, '
              'unaffiliated app.',
              style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                    color: AppTheme.textSecondary.withValues(alpha: 0.85),
                  ),
            ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: () {
                Navigator.of(sheetContext).pop();
                showLicensePage(context: context, applicationName: 'Alexa Look');
              },
              child: const Text('Open source licenses'),
            ),
          ],
        ),
      ),
    ),
  );
}
