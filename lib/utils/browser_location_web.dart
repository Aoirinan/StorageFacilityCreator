import 'dart:html' as html;

/// Full browser navigation (used to leave the SPA for the marketing site).
void assignWindowLocation(String url) {
  html.window.location.assign(url);
}
