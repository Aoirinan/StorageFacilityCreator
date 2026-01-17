import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/contract_model.dart';
import 'package:sfcapp/models/contract_template_model.dart';
import 'package:sfcapp/services/facility_limits_service.dart';

class ContractService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseStorage _storage = FirebaseStorage.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  // Contract CRUD Operations
  static Future<String> createContract({
    required String facilityId,
    required String tenantId,
    required String title,
    required String description,
    required ContractType type,
    String? templateId,
    String? fileUrl,
    DateTime? expiresAt,
    Map<String, dynamic>? customFields,
    String? notes,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      // Check facility contract limit (hard cap: 250)
      final canAdd = await FacilityLimitsService.canAddContract(facilityId);
      if (!canAdd) {
        final currentCount = await FacilityLimitsService.getContractCount(facilityId);
        throw Exception(
          'Contract limit reached. This facility has reached the maximum of ${FacilityLimitsService.maxContractsPerFacility} contracts. '
          'Current count: $currentCount. Please contact support if you need to increase your limit.'
        );
      }

      if (kDebugMode) {
        print('🔄 Creating contract: $title');
      }

      // Get facility owner UID for security rules
      final facilityDoc = await _firestore.collection('facilities').doc(facilityId).get();
      if (!facilityDoc.exists) {
        throw Exception('Facility not found');
      }
      final facilityOwnerUid = facilityDoc.data()!['ownerUid'] as String;

      final ref = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contracts')
          .doc();

      final contractData = {
        'facilityId': facilityId,
        'facilityOwnerUid': facilityOwnerUid,  // ✅ REQUIRED for security rules
        'tenantId': tenantId,
        'title': title,
        'description': description,
        'type': type.name,
        'status': 'draft',
        'templateId': templateId,
        'fileUrl': fileUrl,
        'signedFileUrl': null,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'createdBy': user.uid,
        'sentAt': null,
        'signedAt': null,
        'expiresAt': expiresAt != null ? Timestamp.fromDate(expiresAt) : null,
        'sentBy': null,
        'signedBy': null,
        'customFields': customFields,
        'notes': notes,
        'isActive': true,
      };

      await ref.set(contractData);

      if (kDebugMode) {
        print('✅ Contract created successfully: ${ref.id}');
      }

      return ref.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating contract: $e');
      }
      rethrow;
    }
  }

  // Get contracts for a facility (real-time stream)
  static Stream<List<ContractModel>> getContractsForFacilityStream(String facilityId) {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Setting up contracts stream for facility: $facilityId');
      }

      Query query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contracts')
          .limit(250); // Hard cap: 250 contracts per facility
      
      // Try ordered query, fall back to unordered if index is building
      try {
        query = query.orderBy('createdAt', descending: true);
      } catch (orderingError) {
        if (kDebugMode) {
          print('⚠️ Ordered query not available, using unordered: $orderingError');
        }
      }

      return query.snapshots().map((snapshot) {
        final contracts = snapshot.docs.map((doc) {
          return ContractModel.fromFirestore(doc);
        }).toList();

        // Sort in memory if we used fallback query
        contracts.sort((a, b) => b.createdAt.compareTo(a.createdAt));

        if (kDebugMode) {
          print('📡 Stream update: ${contracts.length} contracts for facility: $facilityId');
        }

        return contracts;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error setting up contracts stream: $e');
      }
      rethrow;
    }
  }

  // Get contracts for a facility
  static Future<List<ContractModel>> getContractsForFacility(String facilityId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Getting contracts for facility: $facilityId');
      }

      // Try ordered query first, fall back to unordered if index is building
      QuerySnapshot snapshot;
      try {
        snapshot = await _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('contracts')
            .orderBy('createdAt', descending: true)
            .limit(250) // Hard cap: 250 contracts per facility
            .get();
      } catch (orderingError) {
        if (orderingError.toString().contains('failed-precondition') && orderingError.toString().contains('index')) {
          if (kDebugMode) {
            print('📋 INDEX BUILDING: Using fallback unordered query for contracts...');
          }
          // Fallback to unordered query
          snapshot = await _firestore
              .collection('facilities')
              .doc(facilityId)
              .collection('contracts')
              .limit(250) // Hard cap: 250 contracts per facility
              .get();
        } else {
          rethrow;
        }
      }

      final contracts = snapshot.docs
          .map((doc) => ContractModel.fromFirestore(doc))
          .toList();
          
      // Sort in memory (needed for fallback queries)
      contracts.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      if (kDebugMode) {
        print('✅ Successfully retrieved ${contracts.length} contracts');
      }

      return contracts;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting contracts: $e');
      }
      return [];
    }
  }

  // Get contracts for a tenant
  static Future<List<ContractModel>> getContractsForTenant(String facilityId, String tenantId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Getting contracts for tenant: $tenantId');
      }

      final querySnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contracts')
          .where('tenantId', isEqualTo: tenantId)
          .where('isActive', isEqualTo: true)
          .orderBy('createdAt', descending: true)
          .get();

      final contracts = querySnapshot.docs
          .map((doc) => ContractModel.fromFirestore(doc))
          .toList();

      if (kDebugMode) {
        print('✅ Successfully retrieved ${contracts.length} contracts for tenant');
      }

      return contracts;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting tenant contracts: $e');
      }
      rethrow;
    }
  }

  // Get a specific contract
  static Future<ContractModel?> getContract(String facilityId, String contractId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Getting contract: $contractId');
      }

      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contracts')
          .doc(contractId)
          .get();

      if (!doc.exists) {
        return null;
      }

      final contract = ContractModel.fromFirestore(doc);
      
      if (kDebugMode) {
        print('✅ Successfully retrieved contract: ${contract.title}');
      }

      return contract;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting contract: $e');
      }
      rethrow;
    }
  }

  // Update contract
  static Future<void> updateContract({
    required String facilityId,
    required String contractId,
    String? title,
    String? description,
    ContractType? type,
    ContractStatus? status,
    String? fileUrl,
    String? signedFileUrl,
    DateTime? sentAt,
    DateTime? signedAt,
    DateTime? expiresAt,
    String? sentBy,
    String? signedBy,
    Map<String, dynamic>? customFields,
    String? notes,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Updating contract: $contractId');
      }

      final updateData = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': user.uid,
      };
      
      if (title != null) updateData['title'] = title;
      if (description != null) updateData['description'] = description;
      if (type != null) updateData['type'] = type.name;
      if (status != null) updateData['status'] = status.name;
      if (fileUrl != null) updateData['fileUrl'] = fileUrl;
      if (signedFileUrl != null) updateData['signedFileUrl'] = signedFileUrl;
      if (sentAt != null) updateData['sentAt'] = Timestamp.fromDate(sentAt);
      if (signedAt != null) updateData['signedAt'] = Timestamp.fromDate(signedAt);
      if (expiresAt != null) updateData['expiresAt'] = Timestamp.fromDate(expiresAt);
      if (sentBy != null) updateData['sentBy'] = sentBy;
      if (signedBy != null) updateData['signedBy'] = signedBy;
      if (customFields != null) updateData['customFields'] = customFields;
      if (notes != null) updateData['notes'] = notes;

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contracts')
          .doc(contractId)
          .update(updateData);

      if (kDebugMode) {
        print('✅ Contract updated successfully: $contractId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error updating contract: $e');
      }
      rethrow;
    }
  }

  // Send contract for signature
  static Future<void> sendContract({
    required String facilityId,
    required String contractId,
    required String sentBy,
    String? tenantEmail,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Sending contract: $contractId');
      }

      // Get contract and tenant details
      final contract = await getContract(facilityId, contractId);
      if (contract == null) {
        throw Exception('Contract not found');
      }

      // Get tenant email if not provided
      String? email = tenantEmail;
      if (email == null) {
        final tenantDoc = await _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .doc(contract.tenantId)
            .get();
        
        if (tenantDoc.exists) {
          final tenantData = tenantDoc.data()!;
          email = tenantData['email'] as String?;
        }
      }

      // Update contract status
      await updateContract(
        facilityId: facilityId,
        contractId: contractId,
        status: ContractStatus.sent,
        sentAt: DateTime.now(),
        sentBy: sentBy,
      );

      // Generate signing token and store it
      final signingToken = _generateSigningToken(contractId, facilityId);
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contracts')
          .doc(contractId)
          .update({
        'signingToken': signingToken,
        'signingTokenExpiresAt': Timestamp.fromDate(
          DateTime.now().add(const Duration(days: 30)),
        ),
      });

      if (kDebugMode) {
        print('✅ Contract sent successfully: $contractId');
        print('📧 Signing token generated: $signingToken');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error sending contract: $e');
      }
      rethrow;
    }
  }

  // Generate a secure signing token for contract access
  static String _generateSigningToken(String contractId, String facilityId) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = DateTime.now().microsecondsSinceEpoch;
    return '${contractId}_${facilityId}_$timestamp$random';
  }

  // Get contract by signing token (for tenant access)
  static Future<ContractModel?> getContractBySigningToken(String signingToken) async {
    try {
      if (kDebugMode) {
        print('🔄 Looking up contract by signing token');
      }

      // Search across all facilities for a contract with this token
      final querySnapshot = await _firestore
          .collectionGroup('contracts')
          .where('signingToken', isEqualTo: signingToken)
          .where('status', isEqualTo: 'sent')
          .limit(1)
          .get();

      if (querySnapshot.docs.isEmpty) {
        return null;
      }

      final doc = querySnapshot.docs.first;
      final contract = ContractModel.fromFirestore(doc);

      // Check if token is expired
      final tokenExpiresAt = doc.data()['signingTokenExpiresAt'] as Timestamp?;
      if (tokenExpiresAt != null && tokenExpiresAt.toDate().isBefore(DateTime.now())) {
        if (kDebugMode) {
          print('⚠️ Signing token expired');
        }
        return null;
      }

      return contract;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting contract by token: $e');
      }
      return null;
    }
  }

  // Sign contract
  static Future<void> signContract({
    required String facilityId,
    required String contractId,
    required String signedBy,
    String? signedFileUrl,
    String? signingToken,
  }) async {
    try {
      // If signing token is provided, validate it (for tenant signing without auth)
      if (signingToken != null) {
        final contract = await getContractBySigningToken(signingToken);
        if (contract == null || contract.id != contractId) {
          throw Exception('Invalid or expired signing token');
        }
      } else {
        // Otherwise, require authentication
        final user = _auth.currentUser;
        if (user == null) {
          throw Exception('Not signed in');
        }
      }

      if (kDebugMode) {
        print('🔄 Signing contract: $contractId');
      }

      await updateContract(
        facilityId: facilityId,
        contractId: contractId,
        status: ContractStatus.signed,
        signedAt: DateTime.now(),
        signedBy: signedBy,
        signedFileUrl: signedFileUrl,
      );

      // Clear signing token after successful signing
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contracts')
          .doc(contractId)
          .update({
        'signingToken': FieldValue.delete(),
        'signingTokenExpiresAt': FieldValue.delete(),
      });

      if (kDebugMode) {
        print('✅ Contract signed successfully: $contractId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error signing contract: $e');
      }
      rethrow;
    }
  }

  // Upload signed contract PDF
  static Future<String> uploadSignedContract({
    required String facilityId,
    required String contractId,
    required Uint8List pdfData,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Uploading signed contract PDF: $contractId');
      }

      final ref = _storage
          .ref()
          .child('facilities/$facilityId/contracts/$contractId/signed_contract.pdf');

      final uploadTask = ref.putData(pdfData);
      final snapshot = await uploadTask;
      final downloadUrl = await snapshot.ref.getDownloadURL();

      if (kDebugMode) {
        print('✅ Signed contract uploaded successfully: $downloadUrl');
      }

      return downloadUrl;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error uploading signed contract: $e');
      }
      rethrow;
    }
  }

  // Archive contract (soft delete)
  static Future<void> archiveContract(String facilityId, String contractId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Archiving contract: $contractId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contracts')
          .doc(contractId)
          .update({
        'isActive': false,
        'archivedAt': FieldValue.serverTimestamp(),
        'archivedByUid': user.uid,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (kDebugMode) {
        print('✅ Contract archived successfully: $contractId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error archiving contract: $e');
      }
      rethrow;
    }
  }

  // Delete contract (hard delete)
  static Future<void> deleteContract(String facilityId, String contractId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Deleting contract: $contractId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contracts')
          .doc(contractId)
          .delete();

      if (kDebugMode) {
        print('✅ Contract deleted successfully: $contractId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error deleting contract: $e');
      }
      rethrow;
    }
  }

  // Upload contract file
  static Future<String> uploadContractFile({
    required String facilityId,
    required String contractId,
    required Uint8List fileData,
    required String fileName,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Uploading contract file: $fileName');
      }

      final ref = _storage
          .ref()
          .child('facilities/$facilityId/contracts/$contractId/$fileName');

      final uploadTask = ref.putData(fileData);
      final snapshot = await uploadTask;
      final downloadUrl = await snapshot.ref.getDownloadURL();

      if (kDebugMode) {
        print('✅ Contract file uploaded successfully: $downloadUrl');
      }

      return downloadUrl;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error uploading contract file: $e');
      }
      rethrow;
    }
  }

  // Contract Template Operations
  static Future<String> createContractTemplate({
    required String facilityId,
    required String name,
    required String description,
    required String content,
    required ContractType type,
    String? createdBy,
    List<TemplateSigner>? signers,
    List<SignaturePlaceholder>? signaturePlaceholders,
    List<String>? requiredFields,
    Map<String, dynamic>? defaultValues,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Creating contract template: $name for facility: $facilityId');
      }

      final ref = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contractTemplates')
          .doc();

      final resolvedSigners = signers ??
          const [
            TemplateSigner(
              id: 'facilityOwner',
              label: 'Facility Owner / Manager',
              role: 'owner',
              isFacilitySigner: true,
              requiresEmail: true,
            ),
            TemplateSigner(
              id: 'tenantPrimary',
              label: 'Primary Tenant / Occupant',
              role: 'tenant',
              isTenantSigner: true,
              requiresEmail: true,
              requiresPhone: true,
            ),
          ];

      final resolvedPlaceholders = signaturePlaceholders ??
          const [
            SignaturePlaceholder(
              id: 'owner-signature',
              signerId: 'facilityOwner',
              fieldType: SignatureFieldType.signature,
              page: 1,
              x: 0.08,
              y: 0.72,
              label: 'Owner Signature',
              tooltip: 'Facility owner or manager signature',
            ),
            SignaturePlaceholder(
              id: 'tenant-signature',
              signerId: 'tenantPrimary',
              fieldType: SignatureFieldType.signature,
              page: 1,
              x: 0.58,
              y: 0.72,
              label: 'Tenant Signature',
              tooltip: 'Primary tenant signature',
            ),
            SignaturePlaceholder(
              id: 'tenant-initials',
              signerId: 'tenantPrimary',
              fieldType: SignatureFieldType.initials,
              page: 1,
              x: 0.58,
              y: 0.81,
              width: 0.12,
              label: 'Tenant Initials',
              tooltip: 'Initial here to acknowledge terms',
            ),
          ];

      final templateData = {
        'name': name,
        'description': description,
        'content': content,
        'type': type.name,
        'facilityId': facilityId, // Required for facility-scoped templates
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'createdBy': createdBy ?? user.uid,
        'isActive': true,
        'requiredFields': requiredFields ?? const <String>[],
        'defaultValues': defaultValues ?? <String, dynamic>{},
        'signers': resolvedSigners.map((signer) => signer.toMap()).toList(),
        'signaturePlaceholders': resolvedPlaceholders.map((field) => field.toMap()).toList(),
      };

      await ref.set(templateData);

      if (kDebugMode) {
        print('✅ Contract template created successfully: ${ref.id}');
      }

      return ref.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating contract template: $e');
      }
      rethrow;
    }
  }

  // Get contract templates for a facility (facility-scoped)
  static Future<List<ContractTemplateModel>> getContractTemplates(String facilityId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Getting contract templates for facility: $facilityId');
      }

      final querySnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contractTemplates')
          .where('isActive', isEqualTo: true)
          .orderBy('name')
          .get();

      final templates = querySnapshot.docs
          .map((doc) => ContractTemplateModel.fromFirestore(doc))
          .toList();

      if (kDebugMode) {
        print('✅ Successfully retrieved ${templates.length} contract templates for facility: $facilityId');
      }

      return templates;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting contract templates: $e');
      }
      return [];
    }
  }

  // Get contract template by ID (facility-scoped)
  static Future<ContractTemplateModel?> getContractTemplate({
    required String facilityId,
    required String templateId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Getting contract template: $templateId for facility: $facilityId');
      }

      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contractTemplates')
          .doc(templateId)
          .get();

      if (!doc.exists) {
        return null;
      }

      final template = ContractTemplateModel.fromFirestore(doc);
      
      if (kDebugMode) {
        print('✅ Successfully retrieved contract template: ${template.name}');
      }

      return template;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting contract template: $e');
      }
      rethrow;
    }
  }

  // Delete contract template (facility-scoped)
  static Future<void> deleteContractTemplate({
    required String facilityId,
    required String templateId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Deleting contract template: $templateId for facility: $facilityId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contractTemplates')
          .doc(templateId)
          .update({
        'isActive': false,
        'updatedAt': FieldValue.serverTimestamp(),
        'deletedBy': user.uid,
      });

      if (kDebugMode) {
        print('✅ Contract template deleted successfully: $templateId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error deleting contract template: $e');
      }
      rethrow;
    }
  }

  // Update contract template (facility-scoped)
  static Future<void> updateContractTemplate({
    required String facilityId,
    required String templateId,
    String? name,
    String? description,
    String? content,
    ContractType? type,
    List<TemplateSigner>? signers,
    List<SignaturePlaceholder>? signaturePlaceholders,
    List<String>? requiredFields,
    Map<String, dynamic>? defaultValues,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Updating contract template: $templateId for facility: $facilityId');
      }

      final updateData = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': user.uid,
      };

      if (name != null) updateData['name'] = name;
      if (description != null) updateData['description'] = description;
      if (content != null) updateData['content'] = content;
      if (type != null) updateData['type'] = type.name;
      if (signers != null) {
        updateData['signers'] = signers.map((signer) => signer.toMap()).toList();
      }
      if (signaturePlaceholders != null) {
        updateData['signaturePlaceholders'] = signaturePlaceholders.map((field) => field.toMap()).toList();
      }
      if (requiredFields != null) updateData['requiredFields'] = requiredFields;
      if (defaultValues != null) updateData['defaultValues'] = defaultValues;

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contractTemplates')
          .doc(templateId)
          .update(updateData);

      if (kDebugMode) {
        print('✅ Contract template updated successfully: $templateId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error updating contract template: $e');
      }
      rethrow;
    }
  }
}