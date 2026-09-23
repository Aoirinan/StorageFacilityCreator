import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service for managing the active facility selection
/// Stores activeFacilityId in both Firestore (users/{uid}) and localStorage
/// null means "All Facilities" view
class ActiveFacilityService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static const String _localStorageKey = 'active_facility_id';
  // Who saved [_localStorageKey]. localStorage is per browser, not per
  // account, so without it the next account to sign in on the same browser
  // started on the previous account's facility.
  static const String _localStorageUidKey = 'active_facility_uid';
  static String? _cachedActiveFacilityId;
  // The uid [_cachedActiveFacilityId] belongs to; it used to outlive sign-out.
  static String? _cachedActiveFacilityUid;

  /// Whether a selection saved in localStorage by [savedByUid] may be used by
  /// [currentUid]. Only a known, different account is refused: a selection
  /// saved before the owner was recorded, or read before auth has restored,
  /// is used exactly as it was before.
  static bool localSelectionBelongsTo({
    required String? savedByUid,
    required String? currentUid,
  }) {
    return savedByUid == null || currentUid == null || savedByUid == currentUid;
  }

  /// The cached id for [uid], or null when none is cached for that account.
  /// Exposed for tests.
  @visibleForTesting
  static String? cachedActiveFacilityIdFor(String? uid) =>
      _cachedActiveFacilityUid == uid ? _cachedActiveFacilityId : null;

  /// Seeds the in-memory cache as a read would. Exposed for tests.
  @visibleForTesting
  static void debugSeedCache(String? uid, String? facilityId) =>
      _setCache(uid, facilityId);

  static void _setCache(String? uid, String? facilityId) {
    _cachedActiveFacilityUid = uid;
    _cachedActiveFacilityId = facilityId;
  }

  static Future<void> _saveLocally(
    SharedPreferences prefs,
    String uid,
    String? facilityId,
  ) async {
    await prefs.setString(_localStorageKey, facilityId ?? '__ALL__');
    await prefs.setString(_localStorageUidKey, uid);
  }

  /// Get the active facility ID from cache, localStorage, or Firestore
  /// Returns null if "All Facilities" is selected
  static Future<String?> getActiveFacilityId() async {
    final uid = _auth.currentUser?.uid;
    // Return cached value if available
    if (_cachedActiveFacilityId != null && _cachedActiveFacilityUid == uid) {
      return _cachedActiveFacilityId;
    }

    try {
      // Try localStorage first (faster)
      final prefs = await SharedPreferences.getInstance();
      final localFacilityId = prefs.getString(_localStorageKey);
      final savedByUid = prefs.getString(_localStorageUidKey);

      if (localFacilityId != null &&
          localSelectionBelongsTo(savedByUid: savedByUid, currentUid: uid)) {
        // Special value for "All Facilities"
        if (localFacilityId == '__ALL__') {
          _setCache(uid, null);
          return null;
        }
        _setCache(uid, localFacilityId);
        return localFacilityId;
      }

      // Fallback to Firestore
      final user = _auth.currentUser;
      if (user != null) {
        final userDoc = await _firestore.collection('users').doc(user.uid).get();
        if (userDoc.exists) {
          final data = userDoc.data();
          final facilityId = data?['activeFacilityId'] as String?;
          
          // Store in localStorage for next time
          await _saveLocally(prefs, user.uid, facilityId);
          
          _setCache(user.uid, facilityId);
          return facilityId;
        }
      }

      // Default: no active facility (All Facilities)
      _setCache(uid, null);
      return null;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ActiveFacilityService] Error getting active facility: $e');
      }
      // On error, default to null (All Facilities)
      return null;
    }
  }

  /// Set the active facility ID
  /// Pass null to select "All Facilities"
  static Future<void> setActiveFacilityId(String? facilityId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      // Update cache
      _setCache(user.uid, facilityId);

      // Update localStorage
      final prefs = await SharedPreferences.getInstance();
      await _saveLocally(prefs, user.uid, facilityId);

      // Update Firestore
      await _firestore.collection('users').doc(user.uid).update({
        'activeFacilityId': facilityId,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (kDebugMode) {
        print('✅ [ActiveFacilityService] Active facility set to: ${facilityId ?? "All Facilities"}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ActiveFacilityService] Error setting active facility: $e');
      }
      rethrow;
    }
  }

  /// Clear cached active facility (useful for logout)
  static void clearCache() {
    _cachedActiveFacilityId = null;
    _cachedActiveFacilityUid = null;
  }

  /// Clear active facility from localStorage (useful for logout)
  static Future<void> clearLocalStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_localStorageKey);
      await prefs.remove(_localStorageUidKey);
      clearCache();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ActiveFacilityService] Error clearing localStorage: $e');
      }
    }
  }
}
