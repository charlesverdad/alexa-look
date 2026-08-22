import 'package:flutter/material.dart';

import 'features/home/home_screen.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(const AlexaLookApp());
}

/// Root widget of the Alexa Look app.
class AlexaLookApp extends StatelessWidget {
  const AlexaLookApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Alexa Look',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: const HomeScreen(),
    );
  }
}
