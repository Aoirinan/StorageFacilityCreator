// Web-only implementation: download bytes as file using browser APIs.
import 'dart:html' as html;
import 'dart:typed_data';

/// Triggers a browser download of [bytes] with [filename].
/// Only call when kIsWeb is true.
void downloadBytesAsFileWeb(Uint8List bytes, String filename) {
  final blob = html.Blob([bytes]);
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..setAttribute('download', filename)
    ..click();
  html.Url.revokeObjectUrl(url);
}
