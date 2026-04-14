// Stub for non-web: never called when kIsWeb is true.

bool openUrlInBrowserWeb(String url) {
  throw UnsupportedError('openUrlInBrowserWeb is only supported on web');
}

void openUrlInCurrentTabWeb(String url) {
  throw UnsupportedError('openUrlInCurrentTabWeb is only supported on web');
}
