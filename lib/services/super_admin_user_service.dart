import 'package:cloud_functions/cloud_functions.dart';

/// Super admin only: user management (delete, disable, enable, send password reset).
/// Calls Cloud Functions that enforce super-admin check on the backend.
class SuperAdminUserService {
  static final _functions = FirebaseFunctions.instance;

  /// Delete user from Firebase Auth and Firestore users collection.
  static Future<void> deleteUser(String uid) async {
    final callable = _functions.httpsCallable('superAdminDeleteUser');
    await callable.call<Map<String, dynamic>>({'uid': uid});
  }

  /// Disable user in Firebase Auth (they cannot sign in).
  static Future<void> disableUser(String uid) async {
    final callable = _functions.httpsCallable('superAdminDisableUser');
    await callable.call<Map<String, dynamic>>({'uid': uid});
  }

  /// Re-enable a disabled user.
  static Future<void> enableUser(String uid) async {
    final callable = _functions.httpsCallable('superAdminEnableUser');
    await callable.call<Map<String, dynamic>>({'uid': uid});
  }

  /// Send password reset email to the user (Firebase Auth link via SendGrid).
  static Future<void> sendPasswordReset(String uid) async {
    final callable = _functions.httpsCallable('superAdminSendPasswordReset');
    await callable.call<Map<String, dynamic>>({'uid': uid});
  }
}
