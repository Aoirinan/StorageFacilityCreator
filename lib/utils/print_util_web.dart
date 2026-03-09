// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

/// Triggers the browser print dialog (web only).
void printWindow() {
  html.window.print();
}
