import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/web_host_config.dart';

/// Persists `?ref=` through email verification until the user has an account doc.
class ReferralProgramService {
  ReferralProgramService._();

  /// Signup URL query key, e.g. `/signup?ref=ABCDEFGH`
  static const String referralSignupQueryParam = 'ref';

  static const String _pendingPrefsKey = 'pending_sfc_referral_code';

  static Future<void> cachePendingCodeFromQuery(String? ref) async {
    final t = ref?.trim().toUpperCase();
    if (t == null || t.isEmpty || t.length < 4) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingPrefsKey, t);
  }

  /// Clears a pending referral (e.g. user removed the optional code on signup).
  static Future<void> clearPendingReferralCode() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingPrefsKey);
  }

  /// Ensures this user has a [referralCode] and applies any pending `?ref=` from signup.
  /// Returns the shareable code when allocation succeeds.
  static Future<String?> syncForCurrentUser() async {
    if (FirebaseAuth.instance.currentUser == null) return null;
    final functions = FirebaseFunctions.instance;
    String? code;
    try {
      final r = await functions.httpsCallable('ensureReferralCodeForAccount').call();
      final data = r.data;
      if (data is Map) {
        final c = data['referralCode'];
        if (c is String && c.trim().isNotEmpty) {
          code = c.trim().toUpperCase();
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('ensureReferralCodeForAccount: $e');
      }
    }

    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getString(_pendingPrefsKey)?.trim().toUpperCase();
    if (pending != null && pending.isNotEmpty) {
      try {
        await functions.httpsCallable('claimReferralAttribution').call(<String, dynamic>{
          'referralCode': pending,
        });
        await prefs.remove(_pendingPrefsKey);
      } catch (e) {
        if (kDebugMode) {
          print('claimReferralAttribution: $e');
        }
      }
    }

    return code;
  }

  static String signupUrlForCode(String referralCode) {
    final c = referralCode.trim().toUpperCase();
    return '${kAppWebOrigin}/signup?$referralSignupQueryParam=${Uri.encodeQueryComponent(c)}';
  }

  /// Where to apply the 3-month referral reward (`null` / empty = first eligible facility).
  static Future<void> setPreferredRewardFacility(String? facilityId) async {
    if (FirebaseAuth.instance.currentUser == null) return;
    final functions = FirebaseFunctions.instance;
    await functions.httpsCallable('setReferralRewardPreferredFacility').call(<String, dynamic>{
      'facilityId': facilityId == null || facilityId.isEmpty ? null : facilityId,
    });
  }
}
