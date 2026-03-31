class SuperAdminAuthUserLookupResult {
  final bool found;
  final SuperAdminAuthUser? user;

  const SuperAdminAuthUserLookupResult({
    required this.found,
    this.user,
  });
}

class SuperAdminAuthUserListPage {
  final List<SuperAdminAuthUser> users;
  final String? nextPageToken;

  const SuperAdminAuthUserListPage({
    required this.users,
    this.nextPageToken,
  });
}

/// Firebase Auth user row returned by super-admin Cloud Functions (not Firestore `users`).
class SuperAdminAuthUser {
  final String uid;
  final String email;
  final bool emailVerified;
  final bool disabled;
  final String? creationTime;
  final String? lastSignInTime;
  final bool hasFirestoreProfile;

  const SuperAdminAuthUser({
    required this.uid,
    required this.email,
    required this.emailVerified,
    required this.disabled,
    this.creationTime,
    this.lastSignInTime,
    required this.hasFirestoreProfile,
  });

  factory SuperAdminAuthUser.fromJson(Map<String, dynamic> json) {
    return SuperAdminAuthUser(
      uid: json['uid'] as String? ?? '',
      email: json['email'] as String? ?? '',
      emailVerified: json['emailVerified'] as bool? ?? false,
      disabled: json['disabled'] as bool? ?? false,
      creationTime: json['creationTime'] as String?,
      lastSignInTime: json['lastSignInTime'] as String?,
      hasFirestoreProfile: json['hasFirestoreProfile'] as bool? ?? false,
    );
  }
}
