/// Marker interface for exceptions that represent a user-initiated
/// cancellation rather than a genuine failure.
///
/// Generic callers that only see "processing this item threw" (e.g.
/// [BatchController](../features/batch/batch_controller.dart)) can check
/// `e is CancelledException` to treat the outcome as "stopped, not failed"
/// — no error UI, no result surfaced as a failure — without needing to know
/// about the specific media pipeline (video, and in future maybe others)
/// that produced it.
abstract interface class CancelledException implements Exception {}
