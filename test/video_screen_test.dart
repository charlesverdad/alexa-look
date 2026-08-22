// Tests for the video editor's "done" stage button
// (lib/features/video/video_screen.dart's VideoDoneView), covering the
// re-save-after-results-screen-dispose fix: once a save has succeeded, the
// Save button must stop being tappable (and must not silently re-attempt a
// save against the temp file that ResultsSession.dispose has since
// deleted), rather than staying enabled and failing with no recovery on a
// second tap.
//
// VideoDoneView is deliberately non-private in video_screen.dart so it can
// be pumped directly here, without needing to drive VideoScreen's real
// picker/ffmpeg pipeline (which isn't mockable in a plain widget test).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alexa_look/features/video/video_screen.dart';

void main() {
  group('VideoDoneView', () {
    testWidgets('before a save: the Save button is enabled and tapping it calls onSave',
        (tester) async {
      var saveCount = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: VideoDoneView(onSave: () => saveCount++),
        ),
      ));

      expect(find.text('Save to gallery'), findsOneWidget);
      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNotNull);

      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      expect(saveCount, 1);
    });

    testWidgets('after a successful save (saved: true): the button is disabled and '
        'relabelled, so a second tap can never re-attempt saving the now-deleted temp file',
        (tester) async {
      var saveCount = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: VideoDoneView(onSave: () => saveCount++, saved: true),
        ),
      ));

      expect(find.text('Saved to gallery'), findsOneWidget);
      expect(find.text('Save to gallery'), findsNothing);

      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNull);

      // Tapping a disabled button is a no-op — onSave must never fire.
      await tester.tap(find.byType(ElevatedButton), warnIfMissed: false);
      await tester.pump();
      expect(saveCount, 0);
    });

    testWidgets('defaults to the not-yet-saved (enabled) state when saved is omitted',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: VideoDoneView(onSave: () {})),
      ));

      expect(find.text('Save to gallery'), findsOneWidget);
      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNotNull);
    });
  });
}
