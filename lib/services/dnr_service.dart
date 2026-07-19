import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/dnr_model.dart';
import 'facility_service.dart';
import 'global_dnr_service.dart';
import 'audit_service.dart';
import 'email_service.dart';

class DNRService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  // Helper method to get user display name
  static Future<String> getUserDisplayName(String uid, String email) async {
    try {
      final userDoc = await _firestore.collection('users').doc(uid).get();
      if (userDoc.exists) {
        final data = userDoc.data();
        final displayName = data?['displayName'] as String?;
        if (displayName != null && displayName.isNotEmpty) {
          return displayName;
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error fetching user display name: $e');
      }
    }
    
    // Fallback to email local part (before @)
    return email.split('@').first;
  }

  // Create a new DNR entry in facility subcollection
  static Future<String> createDNREntry({
    required String facilityId,
    required String name,
    required String email,
    required String phone,
    required String reason,
    String? notes,
    bool active = true,
    DateTime? expiresAt,
    List<String>? evidenceUrls,
    required String facilityName,
    required String ownerEmail,
    required String facilityPhone,
    required String addedByEmail,
    required String addedByName,
    String? linkedTenantId,
    String? linkedTenantName,
    bool accuracyAttested = false,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (!accuracyAttested) {
        throw Exception(
          'You must attest that this entry is factual, supported by your records, and not based on any protected characteristic.',
        );
      }

      if (kDebugMode) {
        print('🔄 Creating DNR entry: $name for facility: $facilityId');
        print('🔄 User UID: ${user.uid}');
        print('🔄 Facility Name: $facilityName');
        print('🔄 Owner Email: $ownerEmail');
        print('🔄 Facility Phone: $facilityPhone');
        print('🔄 Added By Email: $addedByEmail');
        print('🔄 Added By Name: $addedByName');
        if (linkedTenantId != null) {
          print('🔄 Linked Tenant ID: $linkedTenantId');
        }
      }

      // Normalize search fields
      final nameLower = name.toLowerCase();
      final emailLower = email.toLowerCase();
      final phoneDigits = phone.replaceAll(RegExp(r'[^\d]'), '');

      final dnrData = {
        'name': name,
        'nameLower': nameLower,
        'email': email,
        'emailLower': emailLower,
        'phone': phone,
        'phoneDigits': phoneDigits,
        'reason': reason,
        'notes': (notes != null && notes.trim().isNotEmpty) ? notes.trim() : null,
        'active': active,
        'expiresAt': expiresAt != null ? Timestamp.fromDate(expiresAt) : null,
        'evidenceUrls': evidenceUrls ?? [],
        // Submitter attestation: factual, supported by records, not based on a protected characteristic.
        'accuracyAttestation': true,
        'attestedAt': FieldValue.serverTimestamp(),
        'attestedByUid': user.uid,
        'addedAt': FieldValue.serverTimestamp(),
        'addedByUid': user.uid,
        'addedByEmail': addedByEmail,
        'addedByName': addedByName,
        'facilityId': facilityId,
        'facilityName': facilityName,
        'ownerEmail': ownerEmail,
        'facilityPhone': facilityPhone,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedByUid': user.uid,
        'linkedTenantId': linkedTenantId,
        'linkedTenantName': linkedTenantName,
      };

      final docRef = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('dnr')
          .add(dnrData);

      if (kDebugMode) {
        print('✅ DNR entry created with ID: ${docRef.id}');
      }

      // Log audit entry
      await AuditService.logDNRAction(
        facilityId: facilityId,
        action: 'dnr.create',
        targetId: docRef.id,
        details: {
          'name': name,
          'reason': reason,
          'active': active,
        },
      );

      if (linkedTenantId != null && linkedTenantId.isNotEmpty) {
        await _refreshTenantDnrStatus(
          facilityId: facilityId,
          tenantId: linkedTenantId,
        );
      }

      // Don't send automatic email - verification is done before entry creation

      return docRef.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating DNR entry: $e');
      }
      rethrow;
    }
  }

  // Get DNR entries for a specific facility (real-time stream)
  static Stream<List<DNRModel>> getDNREntriesForFacilityStream({
    required String facilityId,
    bool activeOnly = true,
  }) {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        if (kDebugMode) {
          print('❌ DNR Stream: User not signed in');
        }
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Setting up DNR stream for facility: $facilityId, activeOnly: $activeOnly');
        print('🔄 Current user UID: ${user.uid}');
      }

      Query query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('dnr');
      
      if (activeOnly) {
        query = query.where('active', isEqualTo: true);
      }
      
      // Try ordered query, fall back to unordered if index is building
      try {
        query = query.orderBy('addedAt', descending: true);
      } catch (orderingError) {
        if (kDebugMode) {
          print('⚠️ Ordered query not available, using unordered: $orderingError');
        }
      }

      return query.snapshots().map((snapshot) {
        if (kDebugMode) {
          print('📡 DNR Stream: Received snapshot with ${snapshot.docs.length} docs');
        }
        
        final entries = snapshot.docs.map((doc) {
          try {
            return DNRModel.fromFirestore(doc);
          } catch (e) {
            if (kDebugMode) {
              print('❌ DNR Stream: Error parsing doc ${doc.id}: $e');
              print('❌ DNR Stream: Doc data: ${doc.data()}');
            }
            rethrow;
          }
        }).toList();

        // Sort in memory if we used fallback query
        entries.sort((a, b) => b.addedAt.compareTo(a.addedAt));

        if (kDebugMode) {
          print('📡 Stream update: ${entries.length} DNR entries for facility: $facilityId');
        }

        return entries;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error setting up DNR stream: $e');
      }
      rethrow;
    }
  }

  // Get DNR entries for a specific facility
  static Future<List<DNRModel>> getDNREntriesForFacility({
    required String facilityId,
    bool activeOnly = true,
    int limit = 50,
  }) async {
    try {
      Query query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('dnr');

      if (activeOnly) {
        query = query.where('active', isEqualTo: true);
      }

      query = query.orderBy('addedAt', descending: true).limit(limit);

      final snapshot = await query.get();
      return snapshot.docs
          .map((doc) => DNRModel.fromFirestore(doc))
          .toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting DNR entries for facility: $e');
      }
      rethrow;
    }
  }

  // Search DNR entries within a facility
  static Future<List<DNRModel>> searchDNREntries({
    required String facilityId,
    String? query,
    bool? active,
    int limit = 50,
  }) async {
    try {
      Query firestoreQuery = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('dnr');

      if (active != null) {
        firestoreQuery = firestoreQuery.where('active', isEqualTo: active);
      }

      if (query != null && query.isNotEmpty) {
        final searchTerm = query.toLowerCase();
        firestoreQuery = firestoreQuery
            .where('nameLower', isGreaterThanOrEqualTo: searchTerm)
            .where('nameLower', isLessThan: searchTerm + 'z');
      }

      firestoreQuery = firestoreQuery.orderBy('addedAt', descending: true).limit(limit);

      final snapshot = await firestoreQuery.get();
      return snapshot.docs
          .map((doc) => DNRModel.fromFirestore(doc))
          .toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error searching DNR entries: $e');
      }
      rethrow;
    }
  }

  // Check DNR screening for a person (facility DNR via collectionGroup + platform-wide global_dnr_entries)
  static Future<List<DNRModel>> checkDNRScreening({
    required String facilityId, // Kept for context/logging, but search is global
    required String name,
    required String email,
    required String phone,
  }) async {
    try {
      final nameLower = name.toLowerCase();
      final emailLower = email.toLowerCase();
      final phoneDigits = phone.replaceAll(RegExp(r'[^\d]'), '');

      if (kDebugMode) {
        print('🔍 [GLOBAL DNR] Checking DNR screening across ALL facilities');
        print('   Name: $name, Email: $email, Phone: $phone');
      }

      // Use collectionGroup to search across ALL facilities globally
      // Search by name
      final nameQuery = _firestore
          .collectionGroup('dnr')
          .where('active', isEqualTo: true)
          .where('nameLower', isEqualTo: nameLower);

      // Search by email
      final emailQuery = _firestore
          .collectionGroup('dnr')
          .where('active', isEqualTo: true)
          .where('emailLower', isEqualTo: emailLower);

      // Search by phone
      final phoneQuery = _firestore
          .collectionGroup('dnr')
          .where('active', isEqualTo: true)
          .where('phoneDigits', isEqualTo: phoneDigits);

      final results = await Future.wait([
        nameQuery.get(),
        emailQuery.get(),
        phoneQuery.get(),
      ]);

      final allDocs = <QueryDocumentSnapshot>[];
      for (final snapshot in results) {
        allDocs.addAll(snapshot.docs);
      }

      // Remove duplicates based on document ID
      final uniqueDocs = <String, QueryDocumentSnapshot>{};
      for (final doc in allDocs) {
        uniqueDocs[doc.id] = doc;
      }

      final matches = uniqueDocs.values
          .map((doc) => DNRModel.fromFirestore(doc))
          .toList();

      // Filter out expired entries
      final now = DateTime.now();
      final activeMatches = matches.where((entry) {
        if (entry.expiresAt != null && entry.expiresAt!.isBefore(now)) {
          return false; // Skip expired
        }
        return true;
      }).toList();

      List<DNRModel> combined = activeMatches;
      try {
        final platformGlobals = await GlobalDNRService.findActiveMatchingEntries(
          name: name,
          email: email,
          phone: phone,
        );
        combined = [
          ...activeMatches,
          ...platformGlobals.map(DNRModel.fromGlobalDnrEntry),
        ];
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ Error checking platform-wide DNR screening: $e');
        }
      }

      if (kDebugMode) {
        print('🔍 [GLOBAL DNR] Found ${combined.length} active DNR matches (facilities + platform-wide)');
      }

      return combined;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error checking DNR screening: $e');
      }
      rethrow;
    }
  }

  // Update DNR entry
  static Future<void> updateDNREntry({
    required String facilityId,
    required String dnrId,
    String? name,
    String? email,
    String? phone,
    String? reason,
    String? notes,
    bool? active,
    DateTime? expiresAt,
    List<String>? evidenceUrls,
    String? facilityName,
    String? ownerEmail,
    String? facilityPhone,
    String? linkedTenantId,
    String? linkedTenantName,
    String? previousLinkedTenantId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      final updateData = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedByUid': user.uid,
      };

      if (name != null) {
        updateData['name'] = name;
        updateData['nameLower'] = name.toLowerCase();
      }

      if (email != null) {
        updateData['email'] = email;
        updateData['emailLower'] = email.toLowerCase();
      }

      if (phone != null) {
        updateData['phone'] = phone;
        updateData['phoneDigits'] = phone.replaceAll(RegExp(r'[^\d]'), '');
      }

      if (reason != null) {
        updateData['reason'] = reason;
      }

      if (notes != null) {
        updateData['notes'] = notes.trim().isEmpty ? null : notes.trim();
      }

      if (active != null) {
        updateData['active'] = active;
      }

      if (expiresAt != null) {
        updateData['expiresAt'] = Timestamp.fromDate(expiresAt);
      }

      if (evidenceUrls != null) {
        updateData['evidenceUrls'] = evidenceUrls;
      }

      if (facilityName != null) {
        updateData['facilityName'] = facilityName;
      }

      if (ownerEmail != null) {
        updateData['ownerEmail'] = ownerEmail;
      }

      if (facilityPhone != null) {
        updateData['facilityPhone'] = facilityPhone;
      }

      if (linkedTenantId != null) {
        updateData['linkedTenantId'] = linkedTenantId;
      } else if (previousLinkedTenantId != null) {
        updateData['linkedTenantId'] = null;
      }

      if (linkedTenantName != null) {
        updateData['linkedTenantName'] = linkedTenantName;
      } else if (previousLinkedTenantId != null && linkedTenantId == null) {
        updateData['linkedTenantName'] = null;
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('dnr')
          .doc(dnrId)
          .update(updateData);

      if (kDebugMode) {
        print('✅ DNR entry updated: $dnrId');
      }

      // Log audit entry with the fields that changed (values captured in updateData)
      await AuditService.logDNRAction(
        facilityId: facilityId,
        action: 'dnr.update',
        targetId: dnrId,
        details: {
          'updatedFields': updateData.keys
              .where((k) => k != 'updatedAt' && k != 'updatedByUid')
              .toList(),
          if (name != null) 'name': name,
          if (reason != null) 'reason': reason,
          if (active != null) 'active': active,
        },
      );

      if (linkedTenantId != null && linkedTenantId.isNotEmpty) {
        await _refreshTenantDnrStatus(
          facilityId: facilityId,
          tenantId: linkedTenantId,
        );
      }

      if (previousLinkedTenantId != null &&
          previousLinkedTenantId.isNotEmpty &&
          previousLinkedTenantId != linkedTenantId) {
        await _refreshTenantDnrStatus(
          facilityId: facilityId,
          tenantId: previousLinkedTenantId,
        );
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error updating DNR entry: $e');
      }
      rethrow;
    }
  }

  // Delete DNR entry
  static Future<void> deleteDNREntry({
    required String facilityId,
    required String dnrId,
  }) async {
    try {
      String? linkedTenantId;
      String? deletedName;
      String? deletedReason;
      final docRef = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('dnr')
          .doc(dnrId);

      final existingDoc = await docRef.get();
      if (existingDoc.exists) {
        final data = existingDoc.data() as Map<String, dynamic>?;
        linkedTenantId = data?['linkedTenantId'] as String?;
        deletedName = data?['name'] as String?;
        deletedReason = data?['reason'] as String?;
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('dnr')
          .doc(dnrId)
          .delete();

      if (kDebugMode) {
        print('✅ DNR entry deleted: $dnrId');
      }

      // Log audit entry preserving what was deleted
      await AuditService.logDNRAction(
        facilityId: facilityId,
        action: 'dnr.delete',
        targetId: dnrId,
        details: {
          if (deletedName != null) 'name': deletedName,
          if (deletedReason != null) 'reason': deletedReason,
        },
      );

      if (linkedTenantId != null && linkedTenantId.isNotEmpty) {
        await _refreshTenantDnrStatus(
          facilityId: facilityId,
          tenantId: linkedTenantId,
        );
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error deleting DNR entry: $e');
      }
      rethrow;
    }
  }

  // Get all DNR entries (for global search)
  static Future<List<DNRModel>> getAllDNREntries({String? facilityId, bool? activeOnly}) async {
    try {
      if (facilityId != null) {
        return await getDNREntriesForFacility(facilityId: facilityId);
      }

      // Get all DNR entries from all facilities
      // Use collection group query to search across all facilities
      Query query = _firestore.collectionGroup('dnr');
      
      // Apply active filter if specified
      if (activeOnly == true) {
        query = query.where('active', isEqualTo: true);
      } else if (activeOnly == false) {
        query = query.where('active', isEqualTo: false);
      }
      // If activeOnly is null, get all entries (no filter)
      
      // Limit to 500 entries for performance (can paginate later if needed)
      query = query.limit(500);
      
      // Fetch entries
      final snapshot = await query.get();

      // Convert to models and sort alphabetically by name (A to Z)
      final entries = snapshot.docs
          .map((doc) => DNRModel.fromFirestore(doc))
          .toList();
      
      // Sort alphabetically by nameLower (case-insensitive)
      entries.sort((a, b) => a.nameLower.compareTo(b.nameLower));
      
      return entries;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting all DNR entries: $e');
      }
      rethrow;
    }
  }

  // Get global DNR entries (from all facilities)
  static Future<List<DNRModel>> getGlobalDNREntries({bool? activeOnly}) async {
    return await getAllDNREntries(activeOnly: activeOnly);
  }

  // Get local DNR entries (from specific facility)
  static Future<List<DNRModel>> getLocalDNREntries(String facilityId) async {
    return await getDNREntriesForFacility(facilityId: facilityId);
  }

  // Find DNR matches for enforcement (collectionGroup dnr + platform-wide global_dnr_entries)
  static Future<List<DNRModel>> findDNRMatches({
    required String facilityId, // Kept for context/logging, but search is global
    String? name,
    String? email,
    String? phone,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔍 [GLOBAL DNR] Searching for DNR matches across ALL facilities');
        print('   Name: $name, Email: $email, Phone: $phone');
      }

      // Use collectionGroup to search across ALL facilities globally
      final query = _firestore
          .collectionGroup('dnr')
          .where('active', isEqualTo: true);

      final snapshot = await query.get();
      final allEntries = snapshot.docs.map((doc) => DNRModel.fromFirestore(doc)).toList();

      // Filter by matches and not expired
      final now = DateTime.now();
      final matches = <DNRModel>[];

      for (final entry in allEntries) {
        bool isMatch = false;

        // Check if expired
        if (entry.expiresAt != null && entry.expiresAt!.isBefore(now)) {
          continue; // Skip expired entries
        }

        // Check name match (case-insensitive contains)
        if (name != null && name.isNotEmpty) {
          final nameLower = name.toLowerCase();
          if (entry.nameLower.contains(nameLower) || nameLower.contains(entry.nameLower)) {
            isMatch = true;
          }
        }

        // Check email match (case-insensitive contains)
        if (email != null && email.isNotEmpty) {
          final emailLower = email.toLowerCase();
          if (entry.emailLower.contains(emailLower) || emailLower.contains(entry.emailLower)) {
            isMatch = true;
          }
        }

        // Check phone match (ends-with on digits only, or exact match)
        if (phone != null && phone.isNotEmpty) {
          final phoneDigits = phone.replaceAll(RegExp(r'[^\d]'), '');
          if (phoneDigits.isNotEmpty) {
            // Match if either ends with the other (handles partial matches)
            if (entry.phoneDigits.endsWith(phoneDigits) || phoneDigits.endsWith(entry.phoneDigits)) {
              isMatch = true;
            }
          }
        }

        if (isMatch) {
          matches.add(entry);
        }
      }

      try {
        final platformGlobals = await GlobalDNRService.findActiveMatchingEntries(
          name: name,
          email: email,
          phone: phone,
        );
        for (final g in platformGlobals) {
          matches.add(DNRModel.fromGlobalDnrEntry(g));
        }
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ Error finding platform-wide DNR matches: $e');
        }
      }

      if (kDebugMode) {
        print('🔍 [GLOBAL DNR] Found ${matches.length} DNR matches (facilities + platform-wide)');
        for (final match in matches) {
          print('   - ${match.name} (${match.facilityName ?? match.facilityId})');
        }
      }

      return matches;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error finding DNR matches: $e');
      }
      rethrow;
    }
  }

  // Toggle DNR active status
  static Future<void> toggleDNRActive({
    required String facilityId,
    required String dnrId,
    required bool active,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      String? linkedTenantId;
      final docRef = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('dnr')
          .doc(dnrId);

      final existingDoc = await docRef.get();
      if (existingDoc.exists) {
        final data = existingDoc.data() as Map<String, dynamic>?;
        if (data != null) {
          linkedTenantId = data['linkedTenantId'] as String?;
        }
      }

      await docRef.update({
        'active': active,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedByUid': user.uid,
      });

      if (kDebugMode) {
        print('✅ DNR entry ${active ? 'activated' : 'deactivated'}: $dnrId');
      }

      // Log audit entry
      await AuditService.logDNRAction(
        facilityId: facilityId,
        action: 'dnr.toggle',
        targetId: dnrId,
        details: {
          'newActiveStatus': active,
        },
      );

      if (linkedTenantId != null && linkedTenantId.isNotEmpty) {
        await _refreshTenantDnrStatus(
          facilityId: facilityId,
          tenantId: linkedTenantId,
        );
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error toggling DNR active status: $e');
      }
      rethrow;
    }
  }

  static Future<void> _refreshTenantDnrStatus({
    required String facilityId,
    required String tenantId,
  }) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('dnr')
          .where('linkedTenantId', isEqualTo: tenantId)
          .where('active', isEqualTo: true)
          .get();

      final hasActive = snapshot.docs.isNotEmpty;

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .update({
        'isOnDNR': hasActive,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error refreshing tenant DNR status: $e');
      }
    }
  }

  // Run backfill for existing DNR entries
  static Future<void> runBackfillIfNeeded() async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        if (kDebugMode) {
          print('⚠️ No user signed in, skipping DNR backfill');
        }
        return;
      }

      if (kDebugMode) {
        print('🔄 Running DNR backfill for user: ${user.uid}');
      }

      final facilities = await FacilityService.getUserFacilities();
      
      for (final facility in facilities) {
        final snapshot = await _firestore
            .collection('facilities')
            .doc(facility.id)
            .collection('dnr')
            .get();

        final batch = _firestore.batch();
        bool needsUpdate = false;

        for (final doc in snapshot.docs) {
          final data = doc.data();
          bool docNeedsUpdate = false;
          final updates = <String, dynamic>{};

          // Fix missing facilityName field
          if (data['facilityName'] == null) {
            updates['facilityName'] = facility.name;
            docNeedsUpdate = true;
            if (kDebugMode) {
              print('🔧 Fixing DNR: ${data['name']} - setting facilityName: ${facility.name}');
            }
          }

          // Fix missing ownerEmail field
          if (data['ownerEmail'] == null) {
            updates['ownerEmail'] = user.email ?? 'No email available';
            docNeedsUpdate = true;
            if (kDebugMode) {
              print('🔧 Fixing DNR: ${data['name']} - setting ownerEmail: ${user.email}');
            }
          }

          if (docNeedsUpdate) {
            batch.update(doc.reference, updates);
            needsUpdate = true;
          }
        }

        if (needsUpdate) {
          await batch.commit();
          if (kDebugMode) {
            print('✅ DNR backfill completed for facility: ${facility.name}');
          }
        }
      }

      if (kDebugMode) {
        print('✅ DNR backfill completed for all facilities');
      }
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error during DNR backfill: $e');
      }
      // Don't rethrow - backfill is non-critical
    }
  }

  /// Send verification code email when a DNR entry is created
  static Future<void> _sendDNRVerificationCodeEmail({
    required String facilityId,
    required String ownerEmail,
    required String dnrName,
  }) async {
    // Skip if no owner email provided
    if (ownerEmail.isEmpty) {
      if (kDebugMode) {
        print('⚠️ Skipping DNR verification code email: no owner email');
      }
      return;
    }

    try {
      // Generate a 6-digit verification code
      final code = (100000 + (DateTime.now().millisecondsSinceEpoch % 900000)).toString();

      final subject = 'DNR Verification Code';
      
      final text = 'Use this code to verify the Do Not Rent request for $dnrName: $code';
      
      final html = '<p>Use this code to verify the Do Not Rent request for <strong>$dnrName</strong>: <strong>$code</strong></p>';

      // Send email
      final result = await EmailService.sendEmail(
        to: ownerEmail,
        subject: subject,
        text: text,
        html: html,
        facilityId: facilityId,
      );

      if (result.success) {
        if (kDebugMode) {
          print('✅ DNR verification code email sent successfully to: $ownerEmail');
          print('📧 Verification code: $code');
        }
      } else {
        if (kDebugMode) {
          print(
            '❌ Failed to send DNR verification code email: ${EmailService.staffEmailFailureHint(result)}',
          );
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error sending DNR verification code email: $e');
      }
      // Don't rethrow - email failure shouldn't break DNR creation
    }
  }
}