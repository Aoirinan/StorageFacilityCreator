import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// [source] without string literals and // comments, so neither can hold a
/// stray parenthesis. Strings go first: a quote inside a comment then has
/// nothing on its line to pair with.
String _code(String source) => source
    .replaceAll(RegExp(r"'(?:[^'\\\n]|\\.)*'"), "''")
    .replaceAll(RegExp(r'"(?:[^"\\\n]|\\.)*"'), '""')
    .replaceAll(RegExp(r'//[^\n]*'), '');

/// The argument list of the ShellRoute(...) call in app_router.dart.
String _shellRouteBlock() {
  final code = _code(File('lib/router/app_router.dart').readAsStringSync());
  final start = code.indexOf('ShellRoute(');
  expect(start, isNot(-1), reason: 'app_router.dart has no ShellRoute');
  var depth = 0;
  for (var i = start + 'ShellRoute'.length; i < code.length; i++) {
    if (code[i] == '(') depth++;
    if (code[i] == ')' && --depth == 0) return code.substring(start, i + 1);
  }
  fail('ShellRoute( is never closed');
}

/// Class name to the lib/ file declaring it.
Map<String, String> _classFiles() {
  final files = <String, String>{};
  final decl = RegExp(r'^(?:abstract\s+)?class\s+([A-Z]\w*)', multiLine: true);
  for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart')) continue;
    for (final m in decl.allMatches(f.readAsStringSync())) {
      files[m.group(1)!] = f.path;
    }
  }
  return files;
}

void main() {
  test('no page inside the ShellRoute wraps itself in ModernPageWrapper', () {
    // AppShell draws the sidebar and top bar for every ShellRoute page.
    // ModernPageWrapper draws them again, so the page showed two sidebars,
    // one inside the other (seen on Payment Links).
    var routes = _shellRouteBlock();
    expect(routes, contains('HomeScreenModern'));
    expect(routes, contains('PaymentLinksManagementScreen'));
    expect(routes, isNot(contains('SuperAdminScreen')),
        reason: 'the scan ran past the ShellRoute');

    // Route helpers spread into the ShellRoute (detail_routes.dart,
    // stays_routes.dart) build their pages in their own files.
    final helperCalls = RegExp(r'\b([a-z]\w*)\s*\(').allMatches(routes).map((m) => m.group(1)!).toSet();
    final helperDecl = RegExp(r'^(?:GoRoute|RouteBase|List<RouteBase>)\s+([a-z]\w*)\s*\(', multiLine: true);
    for (final f in Directory('lib/router').listSync().whereType<File>()) {
      final source = f.readAsStringSync();
      if (helperDecl.allMatches(source).any((m) => helperCalls.contains(m.group(1)))) {
        routes += _code(source);
      }
    }
    expect(routes, contains('StaysHubScreen'), reason: 'stays_routes.dart was not followed');

    final classFiles = _classFiles();
    final built = RegExp(r'\b([A-Z]\w*)\s*\(').allMatches(routes).map((m) => m.group(1)!).toSet();
    final wrapped = <String>[];
    for (final name in built) {
      final path = classFiles[name];
      if (path == null || path.endsWith('modern_page_wrapper.dart')) continue;
      if (_code(File(path).readAsStringSync()).contains('ModernPageWrapper(')) {
        wrapped.add('$name (${path.replaceAll(r'\', '/')})');
      }
    }
    expect(wrapped..sort(), isEmpty,
        reason: 'Inside the ShellRoute use ShellPage (lib/widgets/shell_page.dart) for the title bar.');
  });
}
