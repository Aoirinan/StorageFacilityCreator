import 'package:flutter/foundation.dart';

import 'ai_debug_logger_stub.dart'
    if (dart.library.html) 'ai_debug_logger_web.dart';

void aiDebugLog({
  required String sessionId,
  required String runId,
  required String hypothesisId,
  required String location,
  required String message,
  required Map<String, dynamic> data,
}) {
  if (!kDebugMode) return;
  logToAiDebugEndpoint(
    sessionId: sessionId,
    runId: runId,
    hypothesisId: hypothesisId,
    location: location,
    message: message,
    data: data,
  );
}
