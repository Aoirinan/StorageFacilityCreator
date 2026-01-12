// Web implementation for CSV download
import 'dart:html' as html;

void downloadCsv(String csvContent, String filename) {
  // Create a blob and trigger download (web only)
  final blob = html.Blob([csvContent], 'text/csv');
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..setAttribute('download', filename)
    ..click();
  html.Url.revokeObjectUrl(url);
}

