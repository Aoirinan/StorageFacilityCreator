import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Hosting serves web/index.html for every unknown path, so the page loads at
/// URLs like /tenants/detail. Anything it fetches by a relative URL must be
/// resolved against `<base href>`, not that path, or the catch-all hands back
/// index.html in place of the script and the app never boots.
void main() {
  final html = File('web/index.html').readAsStringSync();
  final head = html.substring(0, html.indexOf('</head>'));

  test('<base href> comes before any script or URL-bearing tag in <head>', () {
    final base = head.indexOf('<base href="\$FLUTTER_BASE_HREF">');
    expect(base, isNonNegative, reason: 'web/index.html lost its <base href>');

    final firstUrlTag =
        RegExp(r'<(script|link|img)\b', caseSensitive: false).firstMatch(head);
    expect(firstUrlTag, isNotNull);
    expect(base, lessThan(firstUrlTag!.start),
        reason: 'A script or link above <base href> resolves relative URLs '
            'against the deep-link path (e.g. /tenants/flutter_bootstrap.js).');
  });

  test('flutter_bootstrap.js is resolved against the base URL', () {
    expect(head, isNot(contains("s.src = 'flutter_bootstrap.js'")));
    expect(head,
        contains("new URL('flutter_bootstrap.js', document.baseURI).href"));
  });
}
