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
///
/// Codes and bare messages are matched whatever their case: on the web a
/// dropped connection (HTTP status 0) comes back from the Firebase JS SDK
/// as code 'internal' with the message 'internal', which the old
/// case-sensitive check showed as "Error deleting facility: internal".
/// A bare internal error is worded like [unreachable]: the call may have
/// reached the server and finished, so the person refreshes to check
/// rather than retrying blind (a facility delete runs for minutes).
CallableFailureException callableFailure(
  FirebaseFunctionsException error, {
  required String permissionDenied,
  required String notFound,
  required String unreachable,
}) {
  final code = error.code
      .trim()
      .toLowerCase()
      .replaceFirst('functions/', '')
      .replaceAll('_', '-');
  final text = (error.message ?? '').trim();
  final normalizedText = text.toLowerCase().replaceAll('_', '-');
  final bareCode = text.isEmpty || normalizedText == code;
  final message = switch (code) {
    'permission-denied' => permissionDenied,
    'not-found' => notFound,
    'unauthenticated' =>
      'Your sign-in has expired. Sign in again, then try again.',
    // The call may have reached the server and finished.
    'unavailable' || 'deadline-exceeded' => unreachable,
    'internal' when bareCode => unreachable,
    _ when !bareCode => text,
    _ => 'Something went wrong on our side. Try again, and contact support '
        'if it keeps happening.',
  };
  return CallableFailureException(message, code: code);
}
