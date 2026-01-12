import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'network_timeout_helper.dart';

/// Helper class to convert technical error messages into user-friendly messages
class ErrorMessageHelper {
  /// Convert any error to a user-friendly message
  static String getUserFriendlyMessage(dynamic error) {
    if (error == null) {
      return 'An unexpected error occurred. Please try again.';
    }

    final errorString = error.toString().toLowerCase();

    // Firebase Auth errors
    if (error is FirebaseAuthException) {
      return _getAuthErrorMessage(error);
    }

    // Firestore errors
    if (error is FirebaseException) {
      return _getFirestoreErrorMessage(error);
    }

    // Cloud Functions errors
    if (error is FirebaseFunctionsException) {
      return _getFunctionsErrorMessage(error);
    }

    // Permission errors
    if (errorString.contains('permission-denied') || 
        errorString.contains('missing or insufficient permissions')) {
      return 'You don\'t have permission to perform this action. Please contact your administrator if you believe this is an error.';
    }

    // Timeout errors
    if (error is TimeoutException) {
      return error.message;
    }

    // Network errors
    if (errorString.contains('network') || 
        errorString.contains('connection') ||
        errorString.contains('timeout') ||
        errorString.contains('failed host lookup') ||
        errorString.contains('timed out')) {
      return 'Network connection error. Please check your internet connection and try again.';
    }

    // Index errors
    if (errorString.contains('index') || 
        errorString.contains('the query requires an index')) {
      return 'Database index is being created. Please wait a moment and refresh the page.';
    }

    // Not found errors
    if (errorString.contains('not found') || 
        errorString.contains('does not exist')) {
      return 'The requested item could not be found. It may have been deleted.';
    }

    // Already exists errors
    if (errorString.contains('already exists') || 
        errorString.contains('duplicate')) {
      return 'This item already exists. Please use a different value.';
    }

    // Validation errors
    if (errorString.contains('invalid') || 
        errorString.contains('validation')) {
      return 'Invalid data provided. Please check your input and try again.';
    }

    // Generic fallback
    return 'An error occurred. Please try again. If the problem persists, contact support.';
  }

  static String _getAuthErrorMessage(FirebaseAuthException error) {
    switch (error.code) {
      case 'user-not-found':
        return 'No account found with this email address.';
      case 'wrong-password':
        return 'Incorrect password. Please try again.';
      case 'email-already-in-use':
        return 'An account with this email already exists.';
      case 'weak-password':
        return 'Password is too weak. Please use a stronger password.';
      case 'invalid-email':
        return 'Invalid email address. Please check and try again.';
      case 'user-disabled':
        return 'This account has been disabled. Please contact support.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait a moment and try again.';
      case 'operation-not-allowed':
        return 'This operation is not allowed. Please contact support.';
      case 'requires-recent-login':
        return 'Please sign in again to complete this action.';
      default:
        return 'Authentication error. Please try again.';
    }
  }

  static String _getFirestoreErrorMessage(FirebaseException error) {
    switch (error.code) {
      case 'permission-denied':
        return 'You don\'t have permission to access this data. Please contact your administrator.';
      case 'unavailable':
        return 'Service temporarily unavailable. Please try again in a moment.';
      case 'deadline-exceeded':
        return 'Request timed out. Please try again.';
      case 'not-found':
        return 'The requested data could not be found.';
      case 'already-exists':
        return 'This item already exists.';
      case 'failed-precondition':
        if (error.message?.toLowerCase().contains('index') == true) {
          return 'Database index is being created. Please wait a moment and refresh.';
        }
        return 'Operation cannot be completed at this time. Please try again.';
      case 'aborted':
        return 'Operation was cancelled. Please try again.';
      case 'out-of-range':
        return 'Invalid data range. Please check your input.';
      case 'unimplemented':
        return 'This feature is not yet available.';
      case 'internal':
        return 'An internal error occurred. Please try again.';
      case 'data-loss':
        return 'Data corruption detected. Please contact support.';
      default:
        return 'Database error. Please try again.';
    }
  }

  static String _getFunctionsErrorMessage(FirebaseFunctionsException error) {
    switch (error.code) {
      case 'unauthenticated':
        return 'Please sign in to use this feature.';
      case 'permission-denied':
        return 'You don\'t have permission to perform this action.';
      case 'invalid-argument':
        return 'Invalid input provided. Please check and try again.';
      case 'not-found':
        return 'The requested resource could not be found.';
      case 'already-exists':
        return 'This item already exists.';
      case 'resource-exhausted':
        return 'Service limit reached. Please try again later.';
      case 'failed-precondition':
        return 'Operation cannot be completed. Please try again.';
      case 'aborted':
        return 'Operation was cancelled. Please try again.';
      case 'out-of-range':
        return 'Invalid data range. Please check your input.';
      case 'unimplemented':
        return 'This feature is not yet available.';
      case 'internal':
        return 'An internal error occurred. Please try again.';
      case 'unavailable':
        return 'Service temporarily unavailable. Please try again.';
      case 'deadline-exceeded':
        return 'Request timed out. Please try again.';
      default:
        return 'An error occurred. Please try again.';
    }
  }
}

