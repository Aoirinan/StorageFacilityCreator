import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sfcapp/services/public_website_status.dart';

final _origin = Uri.parse('https://app.storagefacilitycreator.com');

/// What getPublicWebsiteConfig answers for a live website (trimmed).
String _config(String slug) => jsonEncode({
      'facilityId': 'fac1',
      'facilitySlug': slug,
      'facilityName': 'Main Street Storage',
      'availableCount': 3,
    });

Future<bool> _ask(MockClient client, {String slug = 'main-street'}) =>
    PublicWebsiteStatus.isLive(slug, client: client, origin: _origin);

void main() {
  test('asks getPublicWebsiteConfig for the slug on the app origin', () async {
    final asked = <Uri>[];
    final client = MockClient((req) async {
      asked.add(req.url);
      return http.Response(_config('main-street'), 200);
    });

    expect(await _ask(client), isTrue);
    expect(asked, [
      Uri.parse(
          'https://app.storagefacilitycreator.com/api/public-website?slug=main-street'),
    ]);
  });

  test('a 404 (website off, or no website add-on) is not live', () async {
    final client = MockClient(
        (_) async => http.Response('{"error":"Website not found."}', 404));

    expect(await _ask(client), isFalse);
  });

  test('a server error is not live', () async {
    final client =
        MockClient((_) async => http.Response('{"error":"Internal error."}', 500));

    expect(await _ask(client), isFalse);
  });

  test('a 200 that is not the config (index.html) is not live', () async {
    // A dev server, or a hosting target without the /api rewrite, answers
    // every path with the app's index.html.
    final client = MockClient((_) async =>
        http.Response('<!DOCTYPE html><html><body></body></html>', 200));

    expect(await _ask(client), isFalse);
  });

  test('a JSON answer without the website slug is not live', () async {
    final client = MockClient((_) async => http.Response('{}', 200));

    expect(await _ask(client), isFalse);
  });

  test('a network failure is not live', () async {
    final client =
        MockClient((_) async => throw http.ClientException('offline'));

    expect(await _ask(client), isFalse);
  });

  test('a blank slug is not live and asks nothing', () async {
    var asked = 0;
    final client = MockClient((_) async {
      asked += 1;
      return http.Response(_config('x'), 200);
    });

    expect(await _ask(client, slug: '  '), isFalse);
    expect(asked, 0);
  });

  test('the website unit list the rent links open', () {
    expect(
      PublicWebsiteStatus.websiteUnitsUrl('main-street', origin: _origin)
          .toString(),
      'https://app.storagefacilitycreator.com/w/main-street#unit-list',
    );
  });
}
