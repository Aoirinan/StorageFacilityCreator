// Web-only: open URL in new tab or same tab.
import 'dart:html' as html;

/// Opens [url] in a new tab.
/// Returns true when popup/tab opened, false when blocked.
bool openUrlInBrowserWeb(String url) {
  final dynamic opened = html.window.open(url, '_blank');
  return opened != null;
}

/// Navigates in the current tab.
void openUrlInCurrentTabWeb(String url) {
  html.window.location.href = url;
}
