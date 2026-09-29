import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sfcapp/router/public_rent_entry_page.dart';
import 'package:sfcapp/services/public_website_status.dart';

/// The rent links wait on /api/public-website before deciding where to go
/// (PublicRentEntryPage). A slow answer must end on the rental portal, never
/// on a spinner that does not stop.
void main() {
  testWidgets('a hung website check falls back to the portal after the timeout',
      (tester) async {
    final never = Completer<http.Response>();
    final client = MockClient((_) => never.future);
    var opened = 0;
    await tester.pumpWidget(MaterialApp(
      home: PublicRentEntryPage(
        slug: 'main-street',
        websiteIsLive: (slug) => PublicWebsiteStatus.isLive(slug,
            client: client, origin: Uri.parse('https://app.example')),
        openWebsite: (_) async {
          opened += 1;
          return true;
        },
        buildPortal: (_) => const Text('rental portal'),
      ),
    ));
    await tester.pump(const Duration(seconds: 5));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('rental portal'), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('rental portal'), findsOneWidget);
    expect(opened, 0);
  });

  testWidgets('a response that stalls mid-body also falls back', (tester) async {
    // Headers arrive, the body never finishes.
    final body = StreamController<List<int>>();
    final client = MockClient.streaming((_, __) async =>
        http.StreamedResponse(body.stream, 200));
    await tester.pumpWidget(MaterialApp(
      home: PublicRentEntryPage(
        slug: 'main-street',
        websiteIsLive: (slug) => PublicWebsiteStatus.isLive(slug,
            client: client, origin: Uri.parse('https://app.example')),
        openWebsite: (_) async => fail('must not open'),
        buildPortal: (_) => const Text('rental portal'),
      ),
    ));
    await tester.pump(const Duration(seconds: 7));
    expect(find.text('rental portal'), findsOneWidget);
  });
}
