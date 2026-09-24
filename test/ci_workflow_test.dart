import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The jobs under `jobs:` in a GitHub Actions workflow, by name, each as
/// its own lines.
Map<String, List<String>> _jobs(String workflow) {
  final jobs = <String, List<String>>{};
  List<String>? current;
  var inJobs = false;
  for (final line in const LineSplitter().convert(workflow)) {
    if (line.startsWith('jobs:')) {
      inJobs = true;
      continue;
    }
    if (!inJobs) continue;
    final job = RegExp(r'^  ([A-Za-z0-9_-]+):\s*$').firstMatch(line);
    if (job != null) {
      current = jobs[job.group(1)!] = <String>[];
    } else {
      current?.add(line);
    }
  }
  return jobs;
}

/// Whether [job] runs functions-shared's `npm test`: from its own directory
/// as a matrix package, or with `--prefix functions-shared`. Building it (or
/// vendoring it into another package) does not count.
bool _runsFunctionsSharedTests(List<String> job) {
  final npmTest = RegExp(r'^\s*(- )?run: npm test(\s+--if-present)?\s*$');
  if (job.any((l) => RegExp(r'run: npm test .*--prefix functions-shared').hasMatch(l))) {
    return true;
  }
  final isMatrixPackage =
      job.any((l) => RegExp(r'^\s+- functions-shared\s*(#.*)?$').hasMatch(l)) &&
          job.any((l) => l.contains(r'working-directory: ${{ matrix.package }}'));
  return isMatrixPackage && job.any(npmTest.hasMatch);
}

void main() {
  test('CI runs the functions-shared tests, not just its build', () {
    // functions-shared holds the rules many callables share (the owner
    // account lookup and the "no codebase queries an owner account itself"
    // scan among them); its tests are the only thing that checks them.
    final jobs = _jobs(File('.github/workflows/release-readiness.yml').readAsStringSync());
    final running = [
      for (final e in jobs.entries)
        if (_runsFunctionsSharedTests(e.value)) e.key,
    ];
    expect(running, isNotEmpty,
        reason: 'release-readiness.yml needs a job that runs npm test for functions-shared');

    // `npm test --if-present` is a silent no-op without a test script.
    final scripts = (jsonDecode(File('functions-shared/package.json').readAsStringSync())
        as Map<String, dynamic>)['scripts'] as Map<String, dynamic>;
    expect(scripts['test'], contains('node --test'));
  });

  test('the check tells a test run from a build-only entry', () {
    const buildOnly = '''
jobs:
  functions-remaining:
    strategy:
      matrix:
        package:
          - functions-admin
          - functions-shared
    defaults:
      run:
        working-directory: \${{ matrix.package }}
    steps:
      - run: npm ci
      - run: npm run build
  flutter:
    steps:
      - run: flutter test
''';
    final jobs = _jobs(buildOnly);
    expect(jobs.keys, ['functions-remaining', 'flutter']);
    expect(_runsFunctionsSharedTests(jobs['functions-remaining']!), isFalse);
    expect(
      _runsFunctionsSharedTests([...jobs['functions-remaining']!, '      - run: npm test --if-present']),
      isTrue,
    );
    expect(_runsFunctionsSharedTests(['      - run: npm test --prefix functions-shared']), isTrue);
    expect(_runsFunctionsSharedTests(['          npm ci --prefix functions-shared']), isFalse);
  });
}
