@Skip('Runs only on web platform; skipped in headless test run')

// This is a basic Flutter widget test for SFCAPPFLUTTER.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';

import 'package:sfcapp/main.dart';
import 'package:sfcapp/firebase_options.dart';

void main() {
  testWidgets('SFC App smoke test - app initialization', (WidgetTester tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();

    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    // Build our app and trigger a frame.
    // Note: We wrap in ProviderScope as the app requires it
    await tester.pumpWidget(const ProviderScope(child: SFCApp()));
    await tester.pump();

    // Verify that the app initializes without crashing
    // The app should show either a loading state or login screen
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
