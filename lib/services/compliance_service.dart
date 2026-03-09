import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/rights_attestation_model.dart';
import 'package:sfcapp/models/terms_acceptance_model.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Service for handling compliance-related operations: terms acceptance, rights attestation, reconfirmation
class ComplianceService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  // Current terms version
  static const String currentTosVersion = '1.0';

  // Terms text (should match what's shown in UI exactly, including line breaks)
  static const String termsText = '''Storage Facility Creator ("SFC") provides tools to upload documents and request electronic signatures. SFC does not provide legal advice and does not create, own, or license the documents you upload.

By enabling contract upload and e-signing for your facility, you agree that:

1) Your documents; your responsibility. You are solely responsible for the documents you upload, send, and use (including any association or licensed forms).

2) Rights and permissions. You represent and warrant that you have all necessary rights, permissions, licenses, and consents to upload, store, send, and request signatures on the documents you use in SFC.

3) No distribution by SFC. You understand SFC does not provide association forms or distribute third-party contracts to other customers.

4) Takedown / disabling. If SFC receives a complaint, legal notice, or otherwise believes a document may be unauthorized, SFC may disable the document/template and suspend its use for new signature requests.

5) Indemnification. You agree to defend and indemnify SFC from claims, damages, liabilities, and expenses (including reasonable attorneys' fees) arising out of your documents, your use of third-party or licensed forms, or your violation of any rights or laws.''';

  // Rights attestation text (exact checkbox label)
  static const String rightsAttestationText = 'I confirm I have the legal right to upload and use this document and to request signatures for it (including any association or licensed forms).';

  /// Get hash of terms text for verification
  static String getTermsTextHash() {
    final bytes = utf8.encode(termsText);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Check if facility has accepted terms for contract features
  static Future<bool> hasAcceptedTerms(String facilityId) async {
    try {
      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('compliance')
          .doc('termsAcceptance')
          .get();

      if (!doc.exists) {
        return false;
      }

      final data = doc.data();
      if (data == null) {
        return false;
      }

      // Check if version matches current version
      final acceptedVersion = data['tosVersion'] as String?;
      return acceptedVersion == currentTosVersion;
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error checking terms acceptance: $e');
      }
      return false;
    }
  }

  /// Accept terms for a facility (must be called by facility admin/owner)
  static Future<void> acceptTerms(String facilityId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('📝 Accepting terms for facility: $facilityId');
      }

      final termsAcceptance = TermsAcceptanceModel(
        facilityId: facilityId,
        acceptedAt: DateTime.now(), // Will be replaced by serverTimestamp
        acceptedByUserId: user.uid,
        tosVersion: currentTosVersion,
        textHash: getTermsTextHash(),
      );

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('compliance')
          .doc('termsAcceptance')
          .set({
        'acceptedAt': FieldValue.serverTimestamp(),
        'acceptedByUserId': user.uid,
        'tosVersion': currentTosVersion,
        'textHash': getTermsTextHash(),
      });

      if (kDebugMode) {
        print('✅ Terms accepted successfully');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error accepting terms: $e');
      }
      rethrow;
    }
  }

  /// Record rights attestation when a document is uploaded
  static Future<void> recordRightsAttestation({
    required String facilityId,
    required String documentId, // Contract or template ID
    required String attestationText,
    String? documentSha256,
    String? userAgent,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('📝 Recording rights attestation for document: $documentId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('rightsAttestations')
          .add({
        'facilityId': facilityId,
        'uploaderUserId': user.uid,
        'uploaderEmail': user.email ?? '',
        'timestamp': FieldValue.serverTimestamp(),
        'tosVersion': currentTosVersion,
        'attestationText': attestationText,
        'documentId': documentId,
        if (documentSha256 != null) 'documentSha256': documentSha256,
        if (userAgent != null) 'userAgent': userAgent,
      });

      if (kDebugMode) {
        print('✅ Rights attestation recorded successfully');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error recording rights attestation: $e');
      }
      rethrow;
    }
  }

  /// Check if a licensed form needs reconfirmation (older than 12 months)
  static bool needsReconfirmation(DateTime? lastReconfirmedAt) {
    if (lastReconfirmedAt == null) {
      return false; // Not a licensed form or never confirmed
    }

    final now = DateTime.now();
    final monthsSinceReconfirmation = (now.difference(lastReconfirmedAt).inDays / 30).floor();
    return monthsSinceReconfirmation >= 12;
  }

  /// Reconfirm rights for a licensed form
  static Future<void> reconfirmRights({
    required String facilityId,
    required String documentId, // Contract or template ID
    required String documentType, // 'contract' or 'template'
    required String attestationText,
    String? userAgent,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('📝 Reconfirming rights for $documentType: $documentId');
      }

      // Update the document's lastReconfirmedAt
      final collection = documentType == 'contract' ? 'contracts' : 'contractTemplates';
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection(collection)
          .doc(documentId)
          .update({
        'lastReconfirmedAt': FieldValue.serverTimestamp(),
      });

      // Record new attestation
      await recordRightsAttestation(
        facilityId: facilityId,
        documentId: documentId,
        attestationText: attestationText,
        userAgent: userAgent,
      );

      if (kDebugMode) {
        print('✅ Rights reconfirmed successfully');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error reconfirming rights: $e');
      }
      rethrow;
    }
  }

  /// Get user agent string (web only)
  static String? getUserAgent() {
    // In Flutter web, we can't directly access navigator.userAgent
    // This would need to be passed from the UI layer
    return null;
  }
}
