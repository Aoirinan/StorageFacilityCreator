// Web-only helpers for insurance report export.
import 'dart:html' as html;

Future<void> downloadReportBytes(List<int> bytes, String filename) async {
  final blob = html.Blob([bytes]);
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..download = filename
    ..click();
  html.Url.revokeObjectUrl(url);
}

