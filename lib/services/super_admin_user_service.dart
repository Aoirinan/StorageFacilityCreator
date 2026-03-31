import 'package:cloud_functions/cloud_functions.dart';
import 'package:sfcapp/models/super_admin_auth_user.dart';

/// Super admin only: user management (delete, disable, enable, send password reset).
/// Calls Cloud Functions that enforce super-admin check on the backend.
class SuperAdminUserService {
  static final _functions = FirebaseFunctions.instance;

  /// Look up a Firebase Auth user by email (includes users with no Firestore profile).
  static Future<SuperAdminAuthUserLookupResult> getAuthUserByEmail(
      String email) async {
    final callable =
        _functions.httpsCallable('superAdminGetAuthUserByEmail');
    final result = await callable
        .call<Map<String, dynamic>>({'email': email.trim().toLowerCase()});
    final data = Map<String, dynamic>.from(result.data);
    final found = data['found'] == true;
    if (!found) {
      return const SuperAdminAuthUserLookupResult(found: false, user: null);
    }
    final userMap = data['user'];
    if (userMap is! Map) {
      return const SuperAdminAuthUserLookupResult(found: false, user: null);
    }
    final user = SuperAdminAuthUser.fromJson(
        Map<String, dynamic>.from(userMap as Map<dynamic, dynamic>));
    return SuperAdminAuthUserLookupResult(found: true, user: user);
  }

  /// Paginated Firebase Auth users (newest-first order is not guaranteed by Auth API).
  static Future<SuperAdminAuthUserListPage> listAuthUsers({
    String? pageToken,
    int maxResults = 50,
  }) async {
    final callable = _functions.httpsCallable('superAdminListAuthUsers');
    final payload = <String, dynamic>{
      'maxResults': maxResults,
      if (pageToken != null && pageToken.isNotEmpty) 'pageToken': pageToken,
    };
    final result =
        await callable.call<Map<String, dynamic>>(payload);
    final data = Map<String, dynamic>.from(result.data);
    final rawUsers = data['users'];
    final users = <SuperAdminAuthUser>[];
    if (rawUsers is List) {
      for (final item in rawUsers) {
        if (item is Map) {
          users.add(SuperAdminAuthUser.fromJson(
              Map<String, dynamic>.from(item as Map<dynamic, dynamic>)));
        }
      }
    }
    final next = data['nextPageToken'];
    return SuperAdminAuthUserListPage(
      users: users,
      nextPageToken: next is String && next.isNotEmpty ? next : null,
    );
  }

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
