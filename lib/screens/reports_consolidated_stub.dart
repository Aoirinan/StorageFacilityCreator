// Stub implementation for non-web platforms
void downloadCsv(String csvContent, String filename) {
  // This should never be called on non-web platforms
  // The kIsWeb check in the calling code prevents this
  throw UnsupportedError('CSV download is only supported on web platforms');
}

