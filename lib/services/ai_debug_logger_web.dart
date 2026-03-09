import 'dart:convert';
import 'dart:html' as html;

void logToAiDebugEndpoint({
  required String sessionId,
  required String runId,
  required String hypothesisId,
  required String location,
  required String message,
  required Map<String, dynamic> data,
}) {
  final payload = <String, dynamic>{
    'sessionId': sessionId,
    'runId': runId,
    'hypothesisId': hypothesisId,
    'location': location,
    'message': message,
    'data': data,
    'timestamp': DateTime.now().millisecondsSinceEpoch,
  };

  html.HttpRequest.request(
    'http://127.0.0.1:7243/ingest/748d491a-76f7-4ad4-9e24-f313e3819079',
    method: 'POST',
    sendData: jsonEncode(payload),
    requestHeaders: {'Content-Type': 'application/json'},
  ).catchError((_) {});
}
