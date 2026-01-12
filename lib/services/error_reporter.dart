import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Centralized error/reporting hook.
/// Replace no-op sections with Crashlytics/Sentry wiring when available.
class ErrorReporter {
  static bool _sentryEnabled = false;

  static void enableSentry() {
    _sentryEnabled = true;
  }

  static void reportError(
    Object error,
    StackTrace? stack, {
    String? context,
    Map<String, dynamic>? metadata,
  }) {
    if (kDebugMode) {
      debugPrint('🛠️ Error reported${context != null ? ' [$context]' : ''}: $error');
      if (metadata != null) {
        debugPrint('   Metadata: $metadata');
      }
      if (stack != null) {
        debugPrint(stack.toString());
      }
    }
    if (_sentryEnabled) {
      Sentry.captureException(
        error,
        stackTrace: stack,
        withScope: (scope) {
          if (context != null) {
            scope.setContexts('context', {'location': context});
          }
          if (metadata != null) {
            scope.setContexts('metadata', metadata);
          }
        },
      );
    }
  }

  static void reportInfo(String message) {
    if (kDebugMode) {
      debugPrint('ℹ️ $message');
    }
    if (_sentryEnabled) {
      Sentry.captureMessage(message, level: SentryLevel.info);
    }
  }
}

