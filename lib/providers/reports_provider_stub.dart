// Stub implementation for non-web platforms (mobile, desktop)
// This file provides a fallback for platforms that don't support dart:html
void downloadCsv(String csvContent, String filename) {
  // This should never be called on non-web platforms
  // The kIsWeb check in reports_provider.dart prevents this
  throw UnsupportedError('CSV download is only supported on web platforms');
}
