import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Production-safe debug logger for login flow. Works on live deployed app.
/// - Enable: add ?debug_session=1 to URL (e.g. .../login?debug_session=1 or ...#/login?debug_session=1).
/// - Logs to browser console (DevTools) and in-memory buffer. Use "Copy debug log" on login to grab.
const _ingestUrl =
    'http://127.0.0.1:7243/ingest/748d491a-76f7-4ad4-9e24-f313e3819079';
const _maxBufferLines = 400;

final List<String> _buffer = [];

bool _debugSessionEnabled() {
  if (kDebugMode) return true;
  try {
    return Uri.base.toString().contains('debug_session=1');
  } catch (_) {
    return false;
  }
}

void debugSessionLog({
  required String hypothesisId,
  required String location,
  required String message,
  Map<String, dynamic>? data,
  String runId = 'run1',
  String sessionId = 'debug-session',
}) {
  if (!_debugSessionEnabled()) return;
  final payload = <String, dynamic>{
    'sessionId': sessionId,
    'runId': runId,
    'hypothesisId': hypothesisId,
    'location': location,
    'message': message,
    'data': data ?? const {},
    'timestamp': DateTime.now().millisecondsSinceEpoch,
  };
  final line = jsonEncode(payload);
  debugPrint('[DEBUG_SESSION] $line');
  _buffer.add(line);
  while (_buffer.length > _maxBufferLines) _buffer.removeAt(0);
  try {
    http
        .post(
          Uri.parse(_ingestUrl),
          headers: {'Content-Type': 'application/json'},
          body: line,
        )
        .catchError((_) {});
  } catch (_) {}
}

/// Returns recent NDJSON lines for "Copy debug log". Use when debug_session=1.
List<String> debugSessionLogLines() => List<String>.from(_buffer);

/// Whether debug session logging is active (kDebugMode or ?debug_session=1).
bool isDebugSessionEnabled() => _debugSessionEnabled();
