import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

/// Calls Cloud Functions for autopay: request, enable, disable.
class AutopayService {
  static final _functions = FirebaseFunctions.instance;
  static final _firestore = FirebaseFirestore.instance;

  /// Set which calendar day of the month autopay should target (1–31), or clear override.
  /// Stored on [facilities/{facilityId}/tenants/{tenantId}].autopay.chargeDayOfMonth.
  static Future<void> setAutopayChargeDayOfMonth({
    required String facilityId,
    required String tenantId,
    int? chargeDayOfMonth,
  }) async {
    if (chargeDayOfMonth != null && (chargeDayOfMonth < 1 || chargeDayOfMonth > 31)) {
      throw ArgumentError.value(chargeDayOfMonth, 'chargeDayOfMonth', 'Must be 1–31 or null');
    }
    final ref = _firestore.collection('facilities').doc(facilityId).collection('tenants').doc(tenantId);
    final update = <String, dynamic>{
      'autopay.updatedAt': FieldValue.serverTimestamp(),
      'autopay.updatedBy': 'FACILITY',
    };
    if (chargeDayOfMonth == null) {
      update['autopay.chargeDayOfMonth'] = FieldValue.delete();
    } else {
      update['autopay.chargeDayOfMonth'] = chargeDayOfMonth;
    }
    await ref.update(update);
  }

  /// Request autopay (sets requested=true, enabled=false, status=REQUESTED). Creates notification + event.
  static Future<void> requestTenantAutopay({
    required String facilityId,
    required String tenantId,
    String source = 'TENANT',
  }) async {
    await _functions.httpsCallable('requestTenantAutopay').call({
      'facilityId': facilityId,
      'tenantId': tenantId,
      'source': source,
    });
  }

  /// Enable or disable autopay. When enabling, facility must have Stripe ENABLED and tenant must have a payment method.
  static Future<Map<String, dynamic>> setTenantAutopay({
    required String facilityId,
    required String tenantId,
    required bool enabled,
    String source = 'TENANT',
  }) async {
    final result = await _functions.httpsCallable('setTenantAutopay').call({
      'facilityId': facilityId,
      'tenantId': tenantId,
      'enabled': enabled,
      'source': source,
    });
    return Map<String, dynamic>.from(result.data as Map);
  }

  /// Portal (no Firebase Auth): enable/disable autopay using email + accessCode.
  static Future<Map<String, dynamic>> setTenantAutopayFromPortal({
    required String email,
    required String accessCode,
    required bool enabled,
    String? tenantId,
  }) async {
    final result = await _functions.httpsCallable('setTenantAutopayFromPortal').call({
      'email': email.trim().toLowerCase(),
      'accessCode': accessCode.trim(),
      'enabled': enabled,
      if (tenantId != null && tenantId.isNotEmpty) 'tenantId': tenantId,
    });
    return Map<String, dynamic>.from(result.data as Map);
  }

  /// Stream facility notifications (for unread badge + list)
  static Stream<QuerySnapshot<Map<String, dynamic>>> watchFacilityNotifications(String facilityId) {
    return FirebaseFirestore.instance
        .collection('facilities')
        .doc(facilityId)
        .collection('Notifications')
        .orderBy('createdAt', descending: true)
        .limit(100)
        .snapshots();
  }

  /// Stream autopay events for facility (Autopay Activity). Returns empty stream if facilityId is null/empty to avoid invalid paths and listener crashes.
  static Stream<QuerySnapshot<Map<String, dynamic>>> watchAutopayEvents(String? facilityId) {
    final id = facilityId?.trim() ?? '';
    if (id.isEmpty) return Stream.empty();
    return FirebaseFirestore.instance
        .collection('facilities')
        .doc(id)
        .collection('AutopayEvents')
        .orderBy('createdAt', descending: true)
        .limit(200)
        .snapshots();
  }

  /// Mark notification as read
  static Future<void> markNotificationRead({
    required String facilityId,
    required String notificationId,
  }) async {
    await FirebaseFirestore.instance
        .collection('facilities')
        .doc(facilityId)
        .collection('Notifications')
        .doc(notificationId)
        .update({'readAt': FieldValue.serverTimestamp()});
  }

  /// Count unread notifications for facility
  static Stream<int> watchUnreadNotificationCount(String facilityId) {
    return FirebaseFirestore.instance
        .collection('facilities')
        .doc(facilityId)
        .collection('Notifications')
        .where('readAt', isNull: true)
        .snapshots()
        .map((s) => s.docs.length);
  }
}
