/// Pure decision logic for what to do with a set of picked/shared files,
/// given each one's content-classified [MediaDetectionResult] (see
/// `lib/core/media_detector.dart`). Deliberately free of any Flutter/
/// platform dependency (no `Navigator`, no `XFile`, no picker types) so it's
/// unit-testable with plain fakes — see `test/media_routing_test.dart`. The
/// caller (home screen, share-intent handler) supplies real paths and
/// pushes whatever screen the decision names.
library;

import 'media_detector.dart';

/// One file being routed: its filesystem path plus its already-computed
/// content classification.
class RoutableMedia {
  final String path;
  final MediaDetectionResult detection;

  const RoutableMedia({required this.path, required this.detection});
}

/// A per-file "couldn't use this one" note for a file that didn't classify
/// as anything supported — kept alongside the routing decision so the UI
/// can show a friendly message per skipped file without blocking whatever
/// *did* work.
class UnsupportedMediaError {
  final String path;
  final String message;

  const UnsupportedMediaError({required this.path, required this.message});
}

/// Where a batch of picked/shared files should be routed.
sealed class MediaRoute {
  const MediaRoute();
}

/// Exactly one supported photo (JPEG/PNG/HEIC/WebP/TIFF) was selected —
/// opens the single-photo editor.
class OpenPhotoEditor extends MediaRoute {
  final RoutableMedia media;
  const OpenPhotoEditor(this.media);
}

/// Exactly one supported RAW/DNG file was selected — opens the single-photo
/// editor via the RAW decode chain.
class OpenRawEditor extends MediaRoute {
  final RoutableMedia media;
  const OpenRawEditor(this.media);
}

/// Exactly one supported video was selected — opens the single-video editor.
class OpenVideoEditor extends MediaRoute {
  final RoutableMedia media;
  const OpenVideoEditor(this.media);
}

/// More than one supported item was selected (any mix of photo/RAW/video)
/// — opens the unified batch screen.
class OpenBatch extends MediaRoute {
  final List<RoutableMedia> items;
  const OpenBatch(this.items);
}

/// Nothing usable came out of the selection (empty selection, or every
/// file was unsupported) — nothing to navigate to.
class NothingToRoute extends MediaRoute {
  const NothingToRoute();
}

/// The outcome of [decideMediaRoute]: where to navigate, plus a friendly
/// error per file that didn't classify as anything supported.
class MediaRouteDecision {
  final MediaRoute route;
  final List<UnsupportedMediaError> unsupported;

  const MediaRouteDecision({required this.route, required this.unsupported});
}

/// Splits [items] into supported/unsupported by content category, and
/// decides where to route the supported ones:
///  - zero supported items -> [NothingToRoute] (still reports any
///    [unsupported] errors, so the caller can tell the user why nothing
///    opened).
///  - exactly one supported item -> straight to its single-item editor
///    ([OpenPhotoEditor] / [OpenRawEditor] / [OpenVideoEditor]).
///  - more than one -> [OpenBatch] with every supported item (mixed
///    photo/RAW/video allowed).
MediaRouteDecision decideMediaRoute(List<RoutableMedia> items) {
  final supported = <RoutableMedia>[];
  final unsupported = <UnsupportedMediaError>[];

  for (final item in items) {
    if (item.detection.category == MediaCategory.unsupported) {
      unsupported.add(UnsupportedMediaError(
        path: item.path,
        message: "Couldn't recognize this file's format.",
      ));
    } else {
      supported.add(item);
    }
  }

  if (supported.isEmpty) {
    return MediaRouteDecision(route: const NothingToRoute(), unsupported: unsupported);
  }

  if (supported.length == 1) {
    final item = supported.first;
    final route = switch (item.detection.category) {
      MediaCategory.photo => OpenPhotoEditor(item),
      MediaCategory.raw => OpenRawEditor(item),
      MediaCategory.video => OpenVideoEditor(item),
      MediaCategory.unsupported =>
        throw StateError('Unreachable: unsupported items are filtered above.'),
    };
    return MediaRouteDecision(route: route, unsupported: unsupported);
  }

  return MediaRouteDecision(route: OpenBatch(supported), unsupported: unsupported);
}
