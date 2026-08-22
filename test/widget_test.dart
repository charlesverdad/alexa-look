// Home screen smoke test: the app builds and shows the two primary actions.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alexa_look/main.dart';

void main() {
  testWidgets('Home screen shows Photo and Video actions', (tester) async {
    await tester.pumpWidget(const AlexaLookApp());
    await tester.pumpAndSettle();

    expect(find.text('Alexa Look'), findsOneWidget);
    expect(find.text('Photo'), findsOneWidget);
    expect(find.text('Video'), findsOneWidget);
    expect(find.byIcon(Icons.photo_outlined), findsOneWidget);
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
  });
}
