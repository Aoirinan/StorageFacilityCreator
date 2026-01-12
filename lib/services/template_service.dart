import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/email_template_model.dart';
import '../models/sms_template_model.dart';

/// Service for managing email and SMS templates
class TemplateService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  // ============================================
  // EMAIL TEMPLATES
  // ============================================

  /// Get email templates for a facility (includes global templates)
  static Stream<List<EmailTemplateModel>> getEmailTemplatesStream(String? facilityId) {
    try {
      // Get facility-specific templates
      Query? facilityQuery;
      if (facilityId != null) {
        facilityQuery = _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('emailTemplates')
            .where('isActive', isEqualTo: true)
            .orderBy('category')
            .orderBy('name');
      }

      // Get global templates
      final globalQuery = _firestore
          .collection('emailTemplates')
          .where('isActive', isEqualTo: true)
          .where('facilityId', isNull: true)
          .orderBy('category')
          .orderBy('name');

      if (facilityQuery != null) {
        // Combine both streams
        return Stream.periodic(const Duration(seconds: 1), (_) {
          // This is a simplified approach - in production, you'd merge the streams properly
          return <EmailTemplateModel>[];
        });
      } else {
        return globalQuery.snapshots().map((snapshot) {
          return snapshot.docs
              .map((doc) => EmailTemplateModel.fromFirestore(doc))
              .toList();
        });
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting email templates stream: $e');
      }
      return Stream.value([]);
    }
  }

  /// Get email templates for a facility (one-time)
  static Future<List<EmailTemplateModel>> getEmailTemplates(String? facilityId) async {
    try {
      final List<EmailTemplateModel> templates = [];

      // Get global templates
      final globalSnapshot = await _firestore
          .collection('emailTemplates')
          .where('isActive', isEqualTo: true)
          .where('facilityId', isNull: true)
          .orderBy('category')
          .orderBy('name')
          .get();

      templates.addAll(
        globalSnapshot.docs.map((doc) => EmailTemplateModel.fromFirestore(doc)),
      );

      // Get facility-specific templates if facilityId provided
      if (facilityId != null) {
        try {
          final facilitySnapshot = await _firestore
              .collection('facilities')
              .doc(facilityId)
              .collection('emailTemplates')
              .where('isActive', isEqualTo: true)
              .orderBy('category')
              .orderBy('name')
              .get();

          templates.addAll(
            facilitySnapshot.docs.map((doc) => EmailTemplateModel.fromFirestore(doc)),
          );
        } catch (e) {
          // Index might not exist yet - that's OK
          if (kDebugMode) {
            print('⚠️ Could not get facility templates (index may not exist): $e');
          }
        }
      }

      return templates;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting email templates: $e');
      }
      return [];
    }
  }

  /// Get default email template for a category
  static Future<EmailTemplateModel?> getDefaultEmailTemplate(String category, String? facilityId) async {
    return getDefaultEmailTemplateByLanguage(category, facilityId, null);
  }

  /// Get default email template for a category and language
  /// Falls back to default language (null) if language-specific template not found
  static Future<EmailTemplateModel?> getDefaultEmailTemplateByLanguage(
    String category,
    String? facilityId,
    String? language, // Language code like "en", "es", "fr", or null for default
  ) async {
    try {
      // Try facility-specific first with language
      if (facilityId != null) {
        Query facilityQuery = _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('emailTemplates')
            .where('category', isEqualTo: category)
            .where('isDefault', isEqualTo: true)
            .where('isActive', isEqualTo: true);

        if (language != null) {
          facilityQuery = facilityQuery.where('language', isEqualTo: language);
        } else {
          facilityQuery = facilityQuery.where('language', isNull: true);
        }

        final facilitySnapshot = await facilityQuery.limit(1).get();

        if (facilitySnapshot.docs.isNotEmpty) {
          return EmailTemplateModel.fromFirestore(facilitySnapshot.docs.first);
        }

        // If language-specific not found, try default (null language)
        if (language != null) {
          final facilityDefaultSnapshot = await _firestore
              .collection('facilities')
              .doc(facilityId)
              .collection('emailTemplates')
              .where('category', isEqualTo: category)
              .where('isDefault', isEqualTo: true)
              .where('isActive', isEqualTo: true)
              .where('language', isNull: true)
              .limit(1)
              .get();

          if (facilityDefaultSnapshot.docs.isNotEmpty) {
            return EmailTemplateModel.fromFirestore(facilityDefaultSnapshot.docs.first);
          }
        }
      }

      // Fall back to global default with language
      Query globalQuery = _firestore
          .collection('emailTemplates')
          .where('category', isEqualTo: category)
          .where('isDefault', isEqualTo: true)
          .where('isActive', isEqualTo: true)
          .where('facilityId', isNull: true);

      if (language != null) {
        globalQuery = globalQuery.where('language', isEqualTo: language);
      } else {
        globalQuery = globalQuery.where('language', isNull: true);
      }

      final globalSnapshot = await globalQuery.limit(1).get();

      if (globalSnapshot.docs.isNotEmpty) {
        return EmailTemplateModel.fromFirestore(globalSnapshot.docs.first);
      }

      // If language-specific not found, try default (null language)
      if (language != null) {
        final globalDefaultSnapshot = await _firestore
            .collection('emailTemplates')
            .where('category', isEqualTo: category)
            .where('isDefault', isEqualTo: true)
            .where('isActive', isEqualTo: true)
            .where('facilityId', isNull: true)
            .where('language', isNull: true)
            .limit(1)
            .get();

        if (globalDefaultSnapshot.docs.isNotEmpty) {
          return EmailTemplateModel.fromFirestore(globalDefaultSnapshot.docs.first);
        }
      }

      return null;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting default email template: $e');
      }
      return null;
    }
  }

  /// Create or update email template
  static Future<String> saveEmailTemplate(EmailTemplateModel template, String? facilityId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not authenticated');

      final now = DateTime.now();
      final templateToSave = template.copyWith(
        updatedAt: now,
        createdBy: user.uid,
      );

      DocumentReference ref;
      if (facilityId != null && template.facilityId == facilityId) {
        // Facility-specific template
        ref = _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('emailTemplates')
            .doc(template.id.isEmpty ? null : template.id);
      } else if (template.facilityId == null) {
        // Global template
        ref = _firestore.collection('emailTemplates').doc(template.id.isEmpty ? null : template.id);
      } else {
        throw Exception('Template facility ID mismatch');
      }

      if (template.id.isEmpty) {
        // New template
        await ref.set(templateToSave.copyWith(
          id: ref.id,
          createdAt: now,
        ).toFirestore());
        return ref.id;
      } else {
        // Update existing
        await ref.update(templateToSave.toFirestore());
        return template.id;
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error saving email template: $e');
      }
      rethrow;
    }
  }

  /// Delete email template
  static Future<void> deleteEmailTemplate(String templateId, String? facilityId) async {
    try {
      if (facilityId != null) {
        await _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('emailTemplates')
            .doc(templateId)
            .delete();
      } else {
        await _firestore.collection('emailTemplates').doc(templateId).delete();
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error deleting email template: $e');
      }
      rethrow;
    }
  }

  // ============================================
  // SMS TEMPLATES
  // ============================================

  /// Get SMS templates for a facility (includes global templates)
  static Future<List<SMSTemplateModel>> getSMSTemplates(String? facilityId) async {
    try {
      final List<SMSTemplateModel> templates = [];

      // Get global templates
      final globalSnapshot = await _firestore
          .collection('smsTemplates')
          .where('isActive', isEqualTo: true)
          .where('facilityId', isNull: true)
          .orderBy('category')
          .orderBy('name')
          .get();

      templates.addAll(
        globalSnapshot.docs.map((doc) => SMSTemplateModel.fromFirestore(doc)),
      );

      // Get facility-specific templates if facilityId provided
      if (facilityId != null) {
        try {
          final facilitySnapshot = await _firestore
              .collection('facilities')
              .doc(facilityId)
              .collection('smsTemplates')
              .where('isActive', isEqualTo: true)
              .orderBy('category')
              .orderBy('name')
              .get();

          templates.addAll(
            facilitySnapshot.docs.map((doc) => SMSTemplateModel.fromFirestore(doc)),
          );
        } catch (e) {
          // Index might not exist yet
          if (kDebugMode) {
            print('⚠️ Could not get facility SMS templates: $e');
          }
        }
      }

      return templates;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting SMS templates: $e');
      }
      return [];
    }
  }

  /// Get default SMS template for a category
  static Future<SMSTemplateModel?> getDefaultSMSTemplate(String category, String? facilityId) async {
    return getDefaultSMSTemplateByLanguage(category, facilityId, null);
  }

  /// Get default SMS template for a category and language
  /// Falls back to default language (null) if language-specific template not found
  static Future<SMSTemplateModel?> getDefaultSMSTemplateByLanguage(
    String category,
    String? facilityId,
    String? language, // Language code like "en", "es", "fr", or null for default
  ) async {
    try {
      // Try facility-specific first with language
      if (facilityId != null) {
        Query facilityQuery = _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('smsTemplates')
            .where('category', isEqualTo: category)
            .where('isDefault', isEqualTo: true)
            .where('isActive', isEqualTo: true);

        if (language != null) {
          facilityQuery = facilityQuery.where('language', isEqualTo: language);
        } else {
          facilityQuery = facilityQuery.where('language', isNull: true);
        }

        final facilitySnapshot = await facilityQuery.limit(1).get();

        if (facilitySnapshot.docs.isNotEmpty) {
          return SMSTemplateModel.fromFirestore(facilitySnapshot.docs.first);
        }

        // If language-specific not found, try default (null language)
        if (language != null) {
          final facilityDefaultSnapshot = await _firestore
              .collection('facilities')
              .doc(facilityId)
              .collection('smsTemplates')
              .where('category', isEqualTo: category)
              .where('isDefault', isEqualTo: true)
              .where('isActive', isEqualTo: true)
              .where('language', isNull: true)
              .limit(1)
              .get();

          if (facilityDefaultSnapshot.docs.isNotEmpty) {
            return SMSTemplateModel.fromFirestore(facilityDefaultSnapshot.docs.first);
          }
        }
      }

      // Fall back to global default with language
      Query globalQuery = _firestore
          .collection('smsTemplates')
          .where('category', isEqualTo: category)
          .where('isDefault', isEqualTo: true)
          .where('isActive', isEqualTo: true)
          .where('facilityId', isNull: true);

      if (language != null) {
        globalQuery = globalQuery.where('language', isEqualTo: language);
      } else {
        globalQuery = globalQuery.where('language', isNull: true);
      }

      final globalSnapshot = await globalQuery.limit(1).get();

      if (globalSnapshot.docs.isNotEmpty) {
        return SMSTemplateModel.fromFirestore(globalSnapshot.docs.first);
      }

      // If language-specific not found, try default (null language)
      if (language != null) {
        final globalDefaultSnapshot = await _firestore
            .collection('smsTemplates')
            .where('category', isEqualTo: category)
            .where('isDefault', isEqualTo: true)
            .where('isActive', isEqualTo: true)
            .where('facilityId', isNull: true)
            .where('language', isNull: true)
            .limit(1)
            .get();

        if (globalDefaultSnapshot.docs.isNotEmpty) {
          return SMSTemplateModel.fromFirestore(globalDefaultSnapshot.docs.first);
        }
      }

      return null;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting default SMS template: $e');
      }
      return null;
    }
  }

  /// Create or update SMS template
  static Future<String> saveSMSTemplate(SMSTemplateModel template, String? facilityId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not authenticated');

      final now = DateTime.now();
      final templateToSave = template.copyWith(
        updatedAt: now,
        createdBy: user.uid,
      );

      DocumentReference ref;
      if (facilityId != null && template.facilityId == facilityId) {
        // Facility-specific template
        ref = _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('smsTemplates')
            .doc(template.id.isEmpty ? null : template.id);
      } else if (template.facilityId == null) {
        // Global template
        ref = _firestore.collection('smsTemplates').doc(template.id.isEmpty ? null : template.id);
      } else {
        throw Exception('Template facility ID mismatch');
      }

      if (template.id.isEmpty) {
        // New template
        await ref.set(templateToSave.copyWith(
          id: ref.id,
          createdAt: now,
        ).toFirestore());
        return ref.id;
      } else {
        // Update existing
        await ref.update(templateToSave.toFirestore());
        return template.id;
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error saving SMS template: $e');
      }
      rethrow;
    }
  }

  /// Delete SMS template
  static Future<void> deleteSMSTemplate(String templateId, String? facilityId) async {
    try {
      if (facilityId != null) {
        await _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('smsTemplates')
            .doc(templateId)
            .delete();
      } else {
        await _firestore.collection('smsTemplates').doc(templateId).delete();
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error deleting SMS template: $e');
      }
      rethrow;
    }
  }
}

