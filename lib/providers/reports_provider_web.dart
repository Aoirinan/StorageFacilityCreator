// Web-specific implementation for CSV download
// This file uses dart:html which is only available on web platforms
import 'dart:html' as html;

void downloadCsv(String csvContent, String filename) {
  // Create a Blob from the CSV content
  final blob = html.Blob([csvContent], 'text/csv');
  
  // Create a temporary URL for the blob
  final url = html.Url.createObjectUrlFromBlob(blob);
  
  // Create an anchor element and trigger download
  final anchor = html.AnchorElement(href: url)
    ..setAttribute('download', filename)
    ..click();
  
  // Clean up the temporary URL
  html.Url.revokeObjectUrl(url);
}
