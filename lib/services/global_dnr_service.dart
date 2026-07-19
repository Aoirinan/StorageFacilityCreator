import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import '../models/global_dnr_model.dart';
import 'audit_service.dart';
import 'facility_service.dart';

/// Service for the global DNR collection (global_dnr_entries).
/// Shared across every authenticated SFC operator (single Firestore collection); does not replace facility-scoped DNR.
class GlobalDNRService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final FirebaseStorage _storage = FirebaseStorage.instance;

  static const String _collection = 'global_dnr_entries';
  static const String _storagePrefix = 'dnrEvidence';

  /// Build search tokens from name, email, phone for client-side search.
  static List<String> _buildSearchTokens({
    required String fullName,
    required String email,
    required String phone,
    String? dob,
    String? last4,
  }) {
    final tokens = <String>{};
    final nameLower = fullName.toLowerCase().trim();
    if (nameLower.isNotEmpty) {
      for (final word in nameLower.split(RegExp(r'\s+'))) {
        if (word.length >= 2) tokens.add(word);
      }
      if (nameLower.length >= 2) tokens.add(nameLower);
    }
    final emailLower = email.toLowerCase().trim();
    if (emailLower.isNotEmpty) tokens.add(emailLower);
    final phoneDigits = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (phoneDigits.length >= 4) tokens.add(phoneDigits);
    if (dob != null && dob.isNotEmpty) tokens.add(dob.trim());
    if (last4 != null && last4.length >= 4) tokens.add(last4.trim());
    return tokens.toList()..sort();
  }

  /// Same fuzzy name/email/phone rules as facility DNR screening (`findDNRMatches`).
  static bool globalEntryMatchesTenantSearch({
    required GlobalDNREntryModel entry,
    String? name,
    String? email,
    String? phone,
  }) {
    if (!entry.isActive) return false;
    var isMatch = false;
    if (name != null && name.isNotEmpty) {
      final nameLower = name.toLowerCase();
      final entryNameLower = entry.fullName.toLowerCase();
      if (entryNameLower.contains(nameLower) || nameLower.contains(entryNameLower)) {
        isMatch = true;
      }
    }
    if (email != null && email.isNotEmpty) {
      final emailLower = email.toLowerCase();
      final entryEmail = entry.email.toLowerCase();
      if (entryEmail.contains(emailLower) || emailLower.contains(entryEmail)) {
        isMatch = true;
      }
    }
    if (phone != null && phone.isNotEmpty) {
      final phoneDigits = phone.replaceAll(RegExp(r'[^\d]'), '');
      if (phoneDigits.isNotEmpty) {
        final entryDigits = entry.phone.replaceAll(RegExp(r'[^\d]'), '');
        if (entryDigits.endsWith(phoneDigits) || phoneDigits.endsWith(entryDigits)) {
          isMatch = true;
        }
      }
    }
    return isMatch;
  }

  /// Active platform-wide DNR rows that match the given tenant fields (client-side filter).
  static Future<List<GlobalDNREntryModel>> findActiveMatchingEntries({
    String? name,
    String? email,
    String? phone,
    int fetchLimit = 500,
  }) async {
    final all = await getGlobalDNREntries(limit: fetchLimit, status: GlobalDnrStatus.active);
    return all
        .where((e) => globalEntryMatchesTenantSearch(entry: e, name: name, email: email, phone: phone))
        .toList();
  }

  /// Create a global DNR entry. Caller must be owner/manager of createdByFacilityId (enforced by rules).
  static Future<String> createGlobalDNREntry({
    required String fullName,
    String? dob,
    required String phone,
    required String email,
    String? driversLicenseLast4,
    String? idLast4,
    required String reason,
    String? notes,
    GlobalDnrSeverity severity = GlobalDnrSeverity.medium,
    required String createdByFacilityId,
    String? createdByFacilityName,
    String? createdByState,
    bool accuracyAttested = false,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Not signed in');

    if (reason.trim().isEmpty) throw Exception('Reason is required');

    if (!accuracyAttested) {
      throw Exception(
        'You must attest that this entry is factual, supported by your records, and not based on any protected characteristic.',
      );
    }

    final now = DateTime.now();
    final searchTokens = _buildSearchTokens(
      fullName: fullName,
      email: email,
      phone: phone,
      dob: dob,
      last4: driversLicenseLast4 ?? idLast4,
    );

    final data = {
      'fullName': fullName.trim(),
      if (dob != null && dob.isNotEmpty) 'dob': dob.trim(),
      'phone': phone.trim(),
      'email': email.trim().toLowerCase(),
      if (driversLicenseLast4 != null && driversLicenseLast4.isNotEmpty) 'driversLicenseLast4': driversLicenseLast4,
      if (idLast4 != null && idLast4.isNotEmpty) 'idLast4': idLast4,
      'reason': reason.trim(),
      if (notes != null && notes.isNotEmpty) 'notes': notes.trim(),
      'severity': severity.value,
      'status': GlobalDnrStatus.active.value,
      // Submitter attestation: factual, supported by records, not based on a protected characteristic.
      'accuracyAttestation': true,
      'attestedAt': Timestamp.fromDate(now),
      'attestedByUid': user.uid,
      'createdAt': Timestamp.fromDate(now),
      'createdByUserId': user.uid,
      'createdByFacilityId': createdByFacilityId,
      if (createdByFacilityName != null) 'createdByFacilityName': createdByFacilityName,
      if (createdByState != null) 'createdByState': createdByState,
      'evidenceCount': 0,
      'searchTokens': searchTokens,
    };

    final docRef = await _firestore.collection(_collection).add(data);
    if (kDebugMode) {
      print('✅ [GlobalDNR] Created entry ${docRef.id}');
    }

    await AuditService.logDNRAction(
      facilityId: createdByFacilityId,
      action: 'dnr.global.create',
      targetId: docRef.id,
      details: {
        'fullName': fullName.trim(),
        'reason': reason.trim(),
        'severity': severity.value,
      },
    );

    return docRef.id;
  }

  /// List global DNR entries (paginated). Optional status filter.
  static Future<List<GlobalDNREntryModel>> getGlobalDNREntries({
    GlobalDnrStatus? status,
    int limit = 100,
    DocumentSnapshot? startAfter,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Not signed in');

    Query<Map<String, dynamic>> query = _firestore
        .collection(_collection)
        .orderBy('createdAt', descending: true)
        .limit(limit);

    if (status != null) {
      query = query.where('status', isEqualTo: status.value);
    }
    if (startAfter != null) {
      query = query.startAfterDocument(startAfter);
    }

    final snapshot = await query.get();
    return snapshot.docs
        .map((doc) => GlobalDNREntryModel.fromFirestore(doc))
        .toList();
  }

  /// Stream of global DNR entries for real-time list updates.
  static Stream<List<GlobalDNREntryModel>> getGlobalDNREntriesStream({
    GlobalDnrStatus? status,
    int limit = 100,
  }) {
    Query<Map<String, dynamic>> query = _firestore
        .collection(_collection)
        .orderBy('createdAt', descending: true)
        .limit(limit);

    if (status != null) {
      query = query.where('status', isEqualTo: status.value);
    }

    return query.snapshots().map((snapshot) {
      return snapshot.docs
          .map((doc) => GlobalDNREntryModel.fromFirestore(doc))
          .toList();
    });
  }

  /// Get a single global DNR entry by id.
  static Future<GlobalDNREntryModel?> getGlobalDNREntry(String entryId) async {
    final user = _auth.currentUser;
    if (user == null) return null;

    final doc = await _firestore.collection(_collection).doc(entryId).get();
    if (!doc.exists) return null;
    return GlobalDNREntryModel.fromFirestore(doc);
  }

  /// Update a global DNR entry. Only creator facility staff or superadmin (rules).
  static Future<void> updateGlobalDNREntry({
    required String entryId,
    String? fullName,
    String? dob,
    String? phone,
    String? email,
    String? driversLicenseLast4,
    String? idLast4,
    String? reason,
    String? notes,
    GlobalDnrSeverity? severity,
    GlobalDnrStatus? status,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Not signed in');

    final ref = _firestore.collection(_collection).doc(entryId);
    final current = await ref.get();
    final currentData = current.data() ?? {};
    final updates = <String, dynamic>{
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (fullName != null) updates['fullName'] = fullName.trim();
    if (dob != null) updates['dob'] = dob.trim().isEmpty ? null : dob.trim();
    if (phone != null) updates['phone'] = phone.trim();
    if (email != null) updates['email'] = email.trim().toLowerCase();
    if (driversLicenseLast4 != null) updates['driversLicenseLast4'] = driversLicenseLast4;
    if (idLast4 != null) updates['idLast4'] = idLast4;
    if (reason != null) updates['reason'] = reason.trim();
    if (notes != null) updates['notes'] = notes.trim().isEmpty ? null : notes.trim();
    if (severity != null) updates['severity'] = severity.value;
    if (status != null) updates['status'] = status.value;

    if (fullName != null || email != null || phone != null || dob != null || driversLicenseLast4 != null || idLast4 != null) {
      updates['searchTokens'] = _buildSearchTokens(
        fullName: fullName ?? (currentData['fullName'] as String? ?? ''),
        email: email ?? (currentData['email'] as String? ?? ''),
        phone: phone ?? (currentData['phone'] as String? ?? ''),
        dob: dob ?? currentData['dob'] as String?,
        last4: driversLicenseLast4 ?? idLast4 ?? currentData['driversLicenseLast4'] as String? ?? currentData['idLast4'] as String?,
      );
    }

    await ref.update(updates);
    if (kDebugMode) {
      print('✅ [GlobalDNR] Updated entry $entryId');
    }

    final auditFacilityId = currentData['createdByFacilityId'] as String?;
    if (auditFacilityId != null && auditFacilityId.isNotEmpty) {
      await AuditService.logDNRAction(
        facilityId: auditFacilityId,
        action: 'dnr.global.update',
        targetId: entryId,
        details: {
          'updatedFields': updates.keys
              .where((k) => k != 'updatedAt' && k != 'searchTokens')
              .toList(),
          if (status != null) 'status': status.value,
        },
      );
    }
  }

  /// Delete a global DNR entry (entry doc + evidence docs + evidence files).
  /// Allowed for superadmin or creator-facility staff (enforced by rules).
  static Future<void> deleteGlobalDNREntry(String entryId) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Not signed in');

    final entryRef = _firestore.collection(_collection).doc(entryId);
    final entryDoc = await entryRef.get();
    final entryData = entryDoc.data() ?? {};

    // Best-effort evidence cleanup (files + metadata docs) before entry delete.
    try {
      final evidenceSnapshot = await entryRef.collection('evidence').get();
      for (final doc in evidenceSnapshot.docs) {
        final storagePath = doc.data()['storagePath'] as String?;
        if (storagePath != null && storagePath.isNotEmpty) {
          try {
            await _storage.ref().child(storagePath).delete();
          } catch (e) {
            if (kDebugMode) {
              print('⚠️ [GlobalDNR] Could not delete evidence file $storagePath: $e');
            }
          }
        }
        await doc.reference.delete();
      }
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ [GlobalDNR] Evidence cleanup error for $entryId: $e');
      }
    }

    await entryRef.delete();
    if (kDebugMode) {
      print('✅ [GlobalDNR] Deleted entry $entryId');
    }

    final auditFacilityId = entryData['createdByFacilityId'] as String?;
    if (auditFacilityId != null && auditFacilityId.isNotEmpty) {
      await AuditService.logDNRAction(
        facilityId: auditFacilityId,
        action: 'dnr.global.delete',
        targetId: entryId,
        details: {
          if (entryData['fullName'] != null) 'fullName': entryData['fullName'],
          if (entryData['reason'] != null) 'reason': entryData['reason'],
        },
      );
    }
  }

  /// Search global DNR entries by name, email, or phone (client-side filter).
  static Future<List<GlobalDNREntryModel>> searchGlobalDNREntries({
    required String query,
    GlobalDnrStatus? status,
    int maxResults = 100,
  }) async {
    final list = await getGlobalDNREntries(limit: 500, status: status);
    final term = query.trim().toLowerCase();
    final phoneDigits = term.replaceAll(RegExp(r'[^\d]'), '');
    final filtered = list.where((e) {
      if (e.fullName.toLowerCase().contains(term)) return true;
      if (e.email.toLowerCase().contains(term)) return true;
      if (e.phone.replaceAll(RegExp(r'[^\d]'), '').contains(phoneDigits)) return true;
      if (e.dob != null && e.dob!.contains(term)) return true;
      if (e.driversLicenseLast4 != null && e.driversLicenseLast4!.contains(term)) return true;
      if (e.idLast4 != null && e.idLast4!.contains(term)) return true;
      return false;
    }).take(maxResults).toList();
    return filtered;
  }

  /// List evidence for a global DNR entry.
  static Future<List<GlobalDNREvidenceModel>> getEvidenceList(String entryId) async {
    final user = _auth.currentUser;
    if (user == null) return [];

    final snapshot = await _firestore
        .collection(_collection)
        .doc(entryId)
        .collection('evidence')
        .orderBy('createdAt', descending: true)
        .get();

    return snapshot.docs
        .map((doc) => GlobalDNREvidenceModel.fromFirestore(doc))
        .toList();
  }

  /// Stream evidence for real-time updates.
  static Stream<List<GlobalDNREvidenceModel>> getEvidenceStream(String entryId) {
    return _firestore
        .collection(_collection)
        .doc(entryId)
        .collection('evidence')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => GlobalDNREvidenceModel.fromFirestore(doc))
            .toList());
  }

  /// Upload evidence file and add metadata. Returns the new evidence id.
  static Future<String> addEvidence({
    required String entryId,
    required Uint8List bytes,
    required String filename,
    String? caption,
    bool isPhoto = true,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Not signed in');

    final evidenceId = _firestore.collection(_collection).doc().id;
    final storagePath = '$_storagePrefix/$entryId/$evidenceId/$filename';

    final ref = _storage.ref().child(storagePath);
    final contentType = isPhoto ? _contentTypeFromFilename(filename) : 'application/octet-stream';
    await ref.putData(bytes, SettableMetadata(contentType: contentType));
    final downloadUrl = await ref.getDownloadURL();

    final evidenceData = {
      'type': isPhoto ? 'photo' : 'doc',
      'storagePath': storagePath,
      'downloadUrl': downloadUrl,
      if (caption != null && caption.isNotEmpty) 'caption': caption,
      'createdAt': FieldValue.serverTimestamp(),
      'createdByUserId': user.uid,
    };

    final batch = _firestore.batch();
    final evidenceRef = _firestore
        .collection(_collection)
        .doc(entryId)
        .collection('evidence')
        .doc(evidenceId);
    batch.set(evidenceRef, evidenceData);
    final entryRef = _firestore.collection(_collection).doc(entryId);
    batch.update(entryRef, {
      'evidenceCount': FieldValue.increment(1),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();

    if (kDebugMode) {
      print('✅ [GlobalDNR] Added evidence $evidenceId to entry $entryId');
    }
    return evidenceId;
  }

  static String _contentTypeFromFilename(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      default:
        return 'application/octet-stream';
    }
  }

  /// Check if current user can create global DNR (is owner/manager of at least one facility).
  static Future<bool> canCreateGlobalDNREntry() async {
    final user = _auth.currentUser;
    if (user == null) return false;
    final facilities = await FacilityService.getUserFacilities();
    if (facilities.isEmpty) return false;
    return true;
  }

  /// Get first facility id for the current user (for "Add to Global DNR" default).
  static Future<String?> getCurrentUserFirstFacilityId() async {
    final facilities = await FacilityService.getUserFacilities();
    return facilities.isNotEmpty ? facilities.first.id : null;
  }
}
