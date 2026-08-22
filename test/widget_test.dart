// Home screen smoke test: the app builds and shows the unified media picker.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alexa_look/main.dart';

void main() {
  testWidgets('Home screen shows the unified Select media action', (tester) async {
    await tester.pumpWidget(const AlexaLookApp());
    await tester.pumpAndSettle();

    expect(find.text('Alexa Look'), findsOneWidget);
    expect(find.text('Select media'), findsOneWidget);
    expect(find.text('Browse files…'), findsOneWidget);
    expect(find.byIcon(Icons.add_photo_alternate_outlined), findsOneWidget);
    // The four separate Photo/Video/Batch/RAW actions and the "Licenses"
    // link are gone in favor of one unified picker plus the About sheet
    // tucked behind the version number.
    expect(find.text('Photo'), findsNothing);
    expect(find.text('Video'), findsNothing);
    expect(find.text('Batch'), findsNothing);
    expect(find.text('RAW'), findsNothing);
    expect(find.text('Licenses'), findsNothing);
  });
}
