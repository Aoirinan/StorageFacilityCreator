void logToAiDebugEndpoint({
  required String sessionId,
  required String runId,
  required String hypothesisId,
  required String location,
  required String message,
  required Map<String, dynamic> data,
}) {
  // No-op on non-web platforms.
}
