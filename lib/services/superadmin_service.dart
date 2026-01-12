import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Service to check if a user is a superadmin
/// Superadmins bypass all subscription restrictions and have full access
/// 
/// NOTE: Super admin emails must be kept in sync with:
/// - functions/src/index.ts (SUPER_ADMIN_EMAILS)
/// - firestore.rules (isSuperAdmin function)
/// 
/// To add/remove super admins, update all three locations.
class SuperAdminService {
  // List of superadmin email addresses (case-insensitive)
  // Add your email here to get superadmin access
  // 
  // IMPORTANT: Keep this in sync with functions/src/index.ts and firestore.rules
  static const List<String> superAdminEmails = [
    'russell_forsyth_1992@outlook.com',
    'russellforsyth09091992@gmail.com',
    // Add more superadmin emails here
  ];

  // List of superadmin UIDs (optional, if you want to use UIDs instead)
  static const List<String> superAdminUids = [
    // Add superadmin UIDs here if needed
  ];

  /// Check if the current user is a superadmin
  static bool isSuperAdmin([User? user]) {
    final currentUser = user ?? FirebaseAuth.instance.currentUser;
    if (currentUser == null) return false;

    // Check by email (case-insensitive)
    final email = currentUser.email?.toLowerCase();
    if (email != null) {
      for (final adminEmail in superAdminEmails) {
        if (email == adminEmail.toLowerCase()) {
          if (kDebugMode) {
            print('✅ Superadmin access granted: $email');
          }
          return true;
        }
      }
    }

    // Check by UID
    if (superAdminUids.contains(currentUser.uid)) {
      if (kDebugMode) {
        print('✅ Superadmin access granted (UID): ${currentUser.uid}');
      }
      return true;
    }

    return false;
  }

  /// Check if a specific email is a superadmin
  static bool isEmailSuperAdmin(String email) {
    final lowerEmail = email.toLowerCase();
    return superAdminEmails.any((adminEmail) => 
      adminEmail.toLowerCase() == lowerEmail
    );
  }

  /// Check if a specific UID is a superadmin
  static bool isUidSuperAdmin(String uid) {
    return superAdminUids.contains(uid);
  }
}

