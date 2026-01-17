import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Minimal NDJSON logger for debug runs.
/// Writes to c:\dev\SFCApp\.cursor\debug.log when kDebugMode is true.
class DebugLogger {
  static const _logPath = r'c:\dev\StorageFacilityCreator\.cursor\debug.log';
  static const _sessionId = 'debug-session';

  static void log({
    required String hypothesisId,
    required String location,
    required String message,
    Map<String, dynamic>? data,
    String runId = 'run1',
  }) {
    if (!kDebugMode) return;
    final payload = <String, dynamic>{
      'sessionId': _sessionId,
      'runId': runId,
      'hypothesisId': hypothesisId,
      'location': location,
      'message': message,
      'data': data ?? const {},
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    try {
      final file = File(_logPath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('${jsonEncode(payload)}\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // swallow logging errors in debug mode
    }
  }
}

