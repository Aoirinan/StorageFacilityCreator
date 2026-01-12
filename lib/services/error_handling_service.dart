import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

enum ErrorType {
  network,
  authentication,
  permission,
  validation,
  notFound,
  conflict,
  server,
  unknown,
}

class AppError {
  final String message;
  final String? code;
  final ErrorType type;
  final String? details;
  final DateTime timestamp;
  final StackTrace? stackTrace;

  AppError({
    required this.message,
    this.code,
    required this.type,
    this.details,
    required this.timestamp,
    this.stackTrace,
  });

  @override
  String toString() {
    return 'AppError(type: $type, message: $message, code: $code)';
  }
}

class ErrorHandlingService {
  static final List<AppError> _errorLog = [];

  // Get error log
  static List<AppError> get errorLog => List.unmodifiable(_errorLog);

  // Clear error log
  static void clearErrorLog() {
    _errorLog.clear();
  }

  // Log error
  static void logError(AppError error) {
    _errorLog.add(error);
    if (kDebugMode) {
      print('🚨 Error logged: ${error.message}');
      if (error.stackTrace != null) {
        print('Stack trace: ${error.stackTrace}');
      }
    }
  }

  // Handle Firebase Auth errors
  static AppError handleFirebaseAuthError(FirebaseAuthException e) {
    String message;
    ErrorType type = ErrorType.authentication;

    switch (e.code) {
      case 'user-not-found':
        message = 'No user found with this email address.';
        break;
      case 'wrong-password':
        message = 'Incorrect password. Please try again.';
        break;
      case 'email-already-in-use':
        message = 'An account already exists with this email address.';
        type = ErrorType.conflict;
        break;
      case 'weak-password':
        message = 'Password is too weak. Please choose a stronger password.';
        type = ErrorType.validation;
        break;
      case 'invalid-email':
        message = 'Invalid email address. Please check your email.';
        type = ErrorType.validation;
        break;
      case 'user-disabled':
        message = 'This account has been disabled. Please contact support.';
        break;
      case 'too-many-requests':
        message = 'Too many failed attempts. Please try again later.';
        type = ErrorType.server;
        break;
      case 'network-request-failed':
        message = 'Network error. Please check your internet connection.';
        type = ErrorType.network;
        break;
      case 'requires-recent-login':
        message = 'Please log in again to perform this action.';
        break;
      default:
        message = e.message ?? 'Authentication error occurred.';
    }

    final error = AppError(
      message: message,
      code: e.code,
      type: type,
      details: e.message,
      timestamp: DateTime.now(),
    );

    logError(error);
    return error;
  }

  // Handle Firestore errors
  static AppError handleFirestoreError(FirebaseException e) {
    String message;
    ErrorType type = ErrorType.server;

    switch (e.code) {
      case 'permission-denied':
        message = 'You do not have permission to perform this action.';
        type = ErrorType.permission;
        break;
      case 'not-found':
        message = 'The requested data was not found.';
        type = ErrorType.notFound;
        break;
      case 'already-exists':
        message = 'This item already exists.';
        type = ErrorType.conflict;
        break;
      case 'failed-precondition':
        message = 'The operation failed due to a precondition.';
        break;
      case 'aborted':
        message = 'The operation was aborted. Please try again.';
        break;
      case 'unavailable':
        message = 'Service is temporarily unavailable. Please try again later.';
        type = ErrorType.server;
        break;
      case 'deadline-exceeded':
        message = 'The operation timed out. Please try again.';
        type = ErrorType.network;
        break;
      case 'resource-exhausted':
        message = 'Too many requests. Please try again later.';
        type = ErrorType.server;
        break;
      case 'cancelled':
        message = 'The operation was cancelled.';
        break;
      case 'data-loss':
        message = 'Data loss occurred. Please try again.';
        break;
      case 'unauthenticated':
        message = 'Please log in to continue.';
        type = ErrorType.authentication;
        break;
      case 'unimplemented':
        message = 'This feature is not yet implemented.';
        break;
      case 'internal':
        message = 'An internal error occurred. Please try again.';
        break;
      case 'invalid-argument':
        message = 'Invalid data provided. Please check your input.';
        type = ErrorType.validation;
        break;
      case 'out-of-range':
        message = 'The value is out of range.';
        type = ErrorType.validation;
        break;
      default:
        message = e.message ?? 'A database error occurred.';
    }

    final error = AppError(
      message: message,
      code: e.code,
      type: type,
      details: e.message,
      timestamp: DateTime.now(),
    );

    logError(error);
    return error;
  }

  // Handle generic exceptions
  static AppError handleGenericError(dynamic error, [StackTrace? stackTrace]) {
    String message;
    ErrorType type = ErrorType.unknown;

    if (error is FormatException) {
      message = 'Invalid data format. Please check your input.';
      type = ErrorType.validation;
    } else if (error is ArgumentError) {
      message = 'Invalid argument provided.';
      type = ErrorType.validation;
    } else if (error is StateError) {
      message = 'Invalid state. Please try again.';
    } else if (error is UnimplementedError) {
      message = 'This feature is not yet implemented.';
    } else if (error is UnsupportedError) {
      message = 'This operation is not supported.';
    } else if (error is ConcurrentModificationError) {
      message = 'Data was modified by another process. Please refresh and try again.';
    } else if (error is NoSuchMethodError) {
      message = 'An unexpected error occurred. Please try again.';
    } else if (error is RangeError) {
      message = 'Value is out of range.';
      type = ErrorType.validation;
    } else if (error is TypeError) {
      message = 'Invalid data type. Please check your input.';
      type = ErrorType.validation;
    } else if (error is Exception) {
      message = error.toString();
    } else {
      message = 'An unexpected error occurred: ${error.toString()}';
    }

    final appError = AppError(
      message: message,
      type: type,
      details: error.toString(),
      timestamp: DateTime.now(),
      stackTrace: stackTrace,
    );

    logError(appError);
    return appError;
  }

  // Handle network errors
  static AppError handleNetworkError(dynamic error) {
    String message = 'Network error. Please check your internet connection and try again.';
    
    if (error.toString().contains('SocketException')) {
      message = 'Unable to connect to the server. Please check your internet connection.';
    } else if (error.toString().contains('TimeoutException')) {
      message = 'Request timed out. Please try again.';
    } else if (error.toString().contains('HandshakeException')) {
      message = 'Secure connection failed. Please try again.';
    }

    final appError = AppError(
      message: message,
      type: ErrorType.network,
      details: error.toString(),
      timestamp: DateTime.now(),
    );

    logError(appError);
    return appError;
  }

  // Handle validation errors
  static AppError handleValidationError(String message, {String? field}) {
    final appError = AppError(
      message: message,
      type: ErrorType.validation,
      details: field != null ? 'Field: $field' : null,
      timestamp: DateTime.now(),
    );

    logError(appError);
    return appError;
  }

  // Handle permission errors
  static AppError handlePermissionError(String message) {
    final appError = AppError(
      message: message,
      type: ErrorType.permission,
      timestamp: DateTime.now(),
    );

    logError(appError);
    return appError;
  }

  // Handle not found errors
  static AppError handleNotFoundError(String resource) {
    final appError = AppError(
      message: '$resource not found.',
      type: ErrorType.notFound,
      timestamp: DateTime.now(),
    );

    logError(appError);
    return appError;
  }

  // Handle conflict errors
  static AppError handleConflictError(String message) {
    final appError = AppError(
      message: message,
      type: ErrorType.conflict,
      timestamp: DateTime.now(),
    );

    logError(appError);
    return appError;
  }

  // Get user-friendly error message
  static String getUserFriendlyMessage(AppError error) {
    switch (error.type) {
      case ErrorType.network:
        return 'Please check your internet connection and try again.';
      case ErrorType.authentication:
        return 'Please log in to continue.';
      case ErrorType.permission:
        return 'You do not have permission to perform this action.';
      case ErrorType.validation:
        return error.message;
      case ErrorType.notFound:
        return 'The requested item was not found.';
      case ErrorType.conflict:
        return error.message;
      case ErrorType.server:
        return 'Server error. Please try again later.';
      case ErrorType.unknown:
        return 'An unexpected error occurred. Please try again.';
    }
  }

  // Check if error is retryable
  static bool isRetryable(AppError error) {
    switch (error.type) {
      case ErrorType.network:
      case ErrorType.server:
        return true;
      case ErrorType.authentication:
      case ErrorType.permission:
      case ErrorType.validation:
      case ErrorType.notFound:
      case ErrorType.conflict:
      case ErrorType.unknown:
        return false;
    }
  }

  // Get retry delay based on error type
  static Duration getRetryDelay(AppError error, {int attempt = 1}) {
    switch (error.type) {
      case ErrorType.network:
        return Duration(seconds: 2 * attempt);
      case ErrorType.server:
        return Duration(seconds: 5 * attempt);
      default:
        return Duration(seconds: 1);
    }
  }

  // Format error for display
  static String formatErrorForDisplay(AppError error) {
    final timestamp = error.timestamp.toLocal().toString().substring(0, 19);
    return '[${timestamp}] ${error.type.name.toUpperCase()}: ${error.message}';
  }

  // Get error statistics
  static Map<ErrorType, int> getErrorStatistics() {
    final stats = <ErrorType, int>{};
    
    for (final error in _errorLog) {
      stats[error.type] = (stats[error.type] ?? 0) + 1;
    }
    
    return stats;
  }

  // Get recent errors
  static List<AppError> getRecentErrors({int count = 10}) {
    final sortedErrors = List<AppError>.from(_errorLog)
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    
    return sortedErrors.take(count).toList();
  }

  // Clear old errors
  static void clearOldErrors({Duration maxAge = const Duration(days: 7)}) {
    final cutoff = DateTime.now().subtract(maxAge);
    _errorLog.removeWhere((error) => error.timestamp.isBefore(cutoff));
  }
}
