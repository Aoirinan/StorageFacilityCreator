import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/lead_model.dart';

class LeadService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Create a new lead
  static Future<String> createLead({
    required String facilityId,
    required String name,
    required String email,
    String? phone,
    LeadSource source = LeadSource.other,
    String? desiredUnit,
    String? notes,
  }) async {
    try {
      final user = _auth.currentUser;
      final now = DateTime.now();

      final leadRef = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('leads')
          .doc();

      final leadData = {
        'facilityId': facilityId,
        'source': source.name,
        'stage': LeadStage.inquiry.name,
        'name': name,
        'email': email,
        if (phone != null) 'phone': phone,
        if (desiredUnit != null) 'desiredUnit': desiredUnit,
        if (notes != null) 'notes': notes,
        'createdAt': Timestamp.fromDate(now),
        'updatedAt': Timestamp.fromDate(now),
        if (user != null) 'createdBy': user.uid,
      };

      await leadRef.set(leadData);
      return leadRef.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating lead: $e');
      }
      rethrow;
    }
  }

  /// Update lead stage
  static Future<void> updateLeadStage({
    required String facilityId,
    required String leadId,
    required LeadStage stage,
    String? convertedToTenantId,
  }) async {
    try {
      final leadRef = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('leads')
          .doc(leadId);

      final updateData = <String, dynamic>{
        'stage': stage.name,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (convertedToTenantId != null) {
        updateData['convertedToTenantId'] = convertedToTenantId;
      }

      await leadRef.update(updateData);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error updating lead stage: $e');
      }
      rethrow;
    }
  }

  /// Get all leads for a facility
  static Stream<List<LeadModel>> getLeadsStream(String facilityId) {
    return _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('leads')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => LeadModel.fromFirestore(doc))
            .toList());
  }

  /// Get a single lead
  static Future<LeadModel?> getLead({
    required String facilityId,
    required String leadId,
  }) async {
    try {
      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('leads')
          .doc(leadId)
          .get();

      if (!doc.exists) return null;
      return LeadModel.fromFirestore(doc);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting lead: $e');
      }
      return null;
    }
  }

  /// Update lead notes
  static Future<void> updateLeadNotes({
    required String facilityId,
    required String leadId,
    required String notes,
  }) async {
    try {
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('leads')
          .doc(leadId)
          .update({
        'notes': notes,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error updating lead notes: $e');
      }
      rethrow;
    }
  }
}
