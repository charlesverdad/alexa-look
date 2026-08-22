/// Registers third-party license notices that aren't already picked up
/// automatically by Flutter's package-based license registry (pub
/// dependencies register themselves; vendored, non-pub source like LibRaw
/// does not) — so they show up in the standard Flutter licenses page (see
/// the "Licenses" link on the home screen, which calls [showLicensePage]).
library;

import 'package:flutter/foundation.dart';

/// Call once at app startup, before [runApp].
void registerThirdPartyLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(
      ['LibRaw'],
      'LibRaw 0.21.5 (https://www.libraw.org/) — Copyright (C) 2008-2024 '
      'LibRaw LLC (info@libraw.org).\n\n'
      'Used under the terms of either the GNU Lesser General Public License '
      'version 2.1 (LGPL-2.1), or the Common Development and Distribution '
      'License version 1.0 (CDDL-1.0), at your option.\n\n'
      'This app dynamically loads LibRaw as a shared library (libcamraw.so), '
      'satisfying the LGPL\'s linking terms. A trimmed copy of LibRaw\'s '
      'source is vendored under native/libraw/ in this app\'s own source '
      'repository, along with the complete, unmodified LGPL-2.1 and '
      'CDDL-1.0 license texts and LibRaw\'s own copyright notice (see '
      'native/libraw/LICENSE.LGPL, LICENSE.CDDL, and COPYRIGHT) — this app '
      'is itself open source, so that vendored copy is the authoritative '
      'source for the complete license terms.',
    );
  });
}
