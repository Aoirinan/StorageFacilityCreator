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
  static String? _cachedActiveFacilityId;

  /// Get the active facility ID from cache, localStorage, or Firestore
  /// Returns null if "All Facilities" is selected
  static Future<String?> getActiveFacilityId() async {
    // Return cached value if available
    if (_cachedActiveFacilityId != null) {
      return _cachedActiveFacilityId;
    }

    try {
      // Try localStorage first (faster)
      final prefs = await SharedPreferences.getInstance();
      final localFacilityId = prefs.getString(_localStorageKey);
      
      if (localFacilityId != null) {
        // Special value for "All Facilities"
        if (localFacilityId == '__ALL__') {
          _cachedActiveFacilityId = null;
          return null;
        }
        _cachedActiveFacilityId = localFacilityId;
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
          if (facilityId == null) {
            await prefs.setString(_localStorageKey, '__ALL__');
          } else {
            await prefs.setString(_localStorageKey, facilityId);
          }
          
          _cachedActiveFacilityId = facilityId;
          return facilityId;
        }
      }

      // Default: no active facility (All Facilities)
      _cachedActiveFacilityId = null;
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
      _cachedActiveFacilityId = facilityId;

      // Update localStorage
      final prefs = await SharedPreferences.getInstance();
      if (facilityId == null) {
        await prefs.setString(_localStorageKey, '__ALL__');
      } else {
        await prefs.setString(_localStorageKey, facilityId);
      }

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
  }

  /// Clear active facility from localStorage (useful for logout)
  static Future<void> clearLocalStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_localStorageKey);
      _cachedActiveFacilityId = null;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ActiveFacilityService] Error clearing localStorage: $e');
      }
    }
  }
}
