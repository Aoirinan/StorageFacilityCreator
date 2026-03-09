// Web-only: open URL in new tab or same tab.
import 'dart:html' as html;

/// Opens [url] in a new tab. If popup is blocked, opens in same tab.
/// Only call when kIsWeb is true.
void openUrlInBrowserWeb(String url) {
  final w = html.window.open(url, '_blank');
  if (w == null) {
    html.window.location.href = url;
  }
}
