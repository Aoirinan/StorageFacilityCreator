// Web-only: get current hostname from browser.
import 'dart:html' as html;

String? getHostnameWeb() => html.window.location.hostname;
