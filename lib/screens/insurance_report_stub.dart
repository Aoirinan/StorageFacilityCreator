// Stub for non-web platforms to avoid dart:html dependency during tests.
Future<void> downloadReportBytes(List<int> bytes, String filename) async {
  throw UnsupportedError('Web-only download not supported on this platform');
}

