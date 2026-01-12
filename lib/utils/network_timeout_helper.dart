import 'dart:async';
import 'package:flutter/foundation.dart';

/// Helper class for adding timeout handling to network operations
class NetworkTimeoutHelper {
  /// Default timeout duration for Firestore operations
  static const Duration defaultFirestoreTimeout = Duration(seconds: 30);
  
  /// Default timeout duration for Cloud Functions
  static const Duration defaultFunctionsTimeout = Duration(seconds: 60);
  
  /// Default timeout duration for Storage operations
  static const Duration defaultStorageTimeout = Duration(seconds: 45);

  /// Execute a Future with timeout handling
  /// Returns the result or throws a TimeoutException with user-friendly message
  static Future<T> withTimeout<T>({
    required Future<T> Function() operation,
    Duration timeout = defaultFirestoreTimeout,
    String? operationName,
  }) async {
    try {
      return await operation().timeout(
        timeout,
        onTimeout: () {
          if (kDebugMode) {
            print('⏱️ Timeout after ${timeout.inSeconds}s for operation: ${operationName ?? "unknown"}');
          }
          throw TimeoutException(
            'Operation timed out after ${timeout.inSeconds} seconds. Please check your internet connection and try again.',
            timeout,
          );
        },
      );
    } on TimeoutException catch (e) {
      rethrow;
    } catch (e) {
      // Re-throw other exceptions as-is
      rethrow;
    }
  }

  /// Execute a Future with timeout and retry logic
  /// Retries up to [maxRetries] times with exponential backoff
  static Future<T> withTimeoutAndRetry<T>({
    required Future<T> Function() operation,
    Duration timeout = defaultFirestoreTimeout,
    int maxRetries = 2,
    String? operationName,
  }) async {
    int attempt = 0;
    Exception? lastException;

    while (attempt <= maxRetries) {
      try {
        return await withTimeout(
          operation: operation,
          timeout: timeout,
          operationName: operationName,
        );
      } on TimeoutException catch (e) {
        lastException = e;
        attempt++;
        
        if (attempt > maxRetries) {
          if (kDebugMode) {
            print('❌ Operation failed after $maxRetries retries: ${operationName ?? "unknown"}');
          }
          rethrow;
        }

        // Exponential backoff: wait 1s, 2s, 4s...
        final backoffDelay = Duration(seconds: 1 << (attempt - 1));
        if (kDebugMode) {
          print('🔄 Retrying operation (attempt $attempt/$maxRetries) after ${backoffDelay.inSeconds}s: ${operationName ?? "unknown"}');
        }
        await Future.delayed(backoffDelay);
      } catch (e) {
        // For non-timeout errors, don't retry
        rethrow;
      }
    }

    // Should never reach here, but just in case
    throw lastException ?? Exception('Operation failed after retries');
  }
}

/// Custom TimeoutException for better error handling
class TimeoutException implements Exception {
  final String message;
  final Duration timeout;

  TimeoutException(this.message, this.timeout);

  @override
  String toString() => message;
}

