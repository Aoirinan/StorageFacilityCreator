import 'package:cloud_functions/cloud_functions.dart';

/// A callable that failed, in words the person using the app can act on.
/// The screens used to show the raw error, e.g. "Error deleting tenant:
/// [firebase_functions/permission-denied] ...".
class CallableFailureException implements Exception {
  const CallableFailureException(this.message, {this.code});

  final String message;

  /// The callable's error code, e.g. 'permission-denied'.
  final String? code;

  @override
  String toString() => message;
}

/// Words [error] for the screen. [permissionDenied], [notFound] and
/// [unreachable] are specific to the action. Other codes carry our own
/// callables' messages, which are written for owners; a bare code
/// ("INTERNAL") gets a generic line instead.
CallableFailureException callableFailure(
  FirebaseFunctionsException error, {
  required String permissionDenied,
  required String notFound,
  required String unreachable,
}) {
  final text = (error.message ?? '').trim();
  final bareCode = text.isEmpty ||
      text == error.code.toUpperCase().replaceAll('-', '_');
  final message = switch (error.code) {
    'permission-denied' => permissionDenied,
    'not-found' => notFound,
    'unauthenticated' =>
      'Your sign-in has expired. Sign in again, then try again.',
    // The call may have reached the server and finished.
    'unavailable' || 'deadline-exceeded' => unreachable,
    _ when !bareCode => text,
    _ => 'Something went wrong on our side. Try again, and contact support '
        'if it keeps happening.',
  };
  return CallableFailureException(message, code: error.code);
}
