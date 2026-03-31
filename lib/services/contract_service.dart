import 'dart:convert';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:sfcapp/models/contract_model.dart';
import 'package:sfcapp/models/contract_template_model.dart';
import 'package:sfcapp/services/facility_limits_service.dart';
import 'package:sfcapp/services/compliance_service.dart';
import 'package:sfcapp/services/audit_service.dart';

class ContractService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseStorage _storage = FirebaseStorage.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// On web, fetches via same-origin proxy to avoid Firebase Storage CORS from custom domain.
  /// Returns proxy URL when on web and fileUrl is firebasestorage; otherwise returns fileUrl.
  static String getPdfFetchUrl(String? fileUrl) {
    if (fileUrl == null || fileUrl.isEmpty) return fileUrl ?? '';
    if (!kIsWeb) return fileUrl;
    final isGoogleStorageUrl =
        fileUrl.contains('firebasestorage.googleapis.com') ||
        fileUrl.contains('storage.googleapis.com');
    if (!isGoogleStorageUrl) return fileUrl;
    final proxyPath = '/api/proxyContractPdf?url=${Uri.encodeComponent(fileUrl)}';
    try {
      return Uri.base.resolve(proxyPath).toString();
    } catch (_) {
      return fileUrl;
    }
  }

  /// Signing token time-to-live (14 days). Configurable for security hardening.
  static const Duration signingTokenTtl = Duration(days: 14);

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
    String? signedByEmail,
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
      if (signedByEmail != null) updateData['signedByEmail'] = signedByEmail;
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

      // Generate signing token and store it (TTL configurable for security hardening)
      final signingToken = _generateSigningToken(contractId, facilityId);
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contracts')
          .doc(contractId)
          .update({
        'signingToken': signingToken,
        'signingTokenExpiresAt': Timestamp.fromDate(
          DateTime.now().add(ContractService.signingTokenTtl),
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

  /// Resend contract for signature (regenerates signing token and extends expiry).
  /// Returns the new signing token for immediate use (avoids read-after-write race).
  static Future<String> resendContract({
    required String facilityId,
    required String contractId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      final contract = await getContract(facilityId, contractId);
      if (contract == null) {
        throw Exception('Contract not found');
      }
      if (contract.status != ContractStatus.sent) {
        throw Exception('Can only resend contracts that have been sent');
      }

      final signingToken = _generateSigningToken(contractId, facilityId);
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contracts')
          .doc(contractId)
          .update({
        'signingToken': signingToken,
        'signingTokenExpiresAt': Timestamp.fromDate(
          DateTime.now().add(ContractService.signingTokenTtl),
        ),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (kDebugMode) {
        print('✅ Contract resend token generated: $contractId');
      }
      return signingToken;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error resending contract: $e');
      }
      rethrow;
    }
  }

  // Get contract by signing token (for tenant access via email link - uses Cloud Function to bypass Firestore rules)
  static Future<ContractModel?> getContractBySigningToken(String signingToken) async {
    try {
      if (kDebugMode) {
        print('🔄 Looking up contract by signing token via Cloud Function');
      }

      final callable = FirebaseFunctions.instance.httpsCallable('getContractBySigningToken');
      final result = await callable.call<Map<String, dynamic>>({'signingToken': signingToken});
      final data = result.data;

      if (data == null) return null;

      final id = data['id'] as String? ?? '';
      if (id.isEmpty) return null;

      return ContractModel.fromMap(data, id: id);
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
    String? signedByEmail,
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
        signedByEmail: signedByEmail,
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

  // Upload signed contract PDF via Cloud Function (bypasses Storage CORS from custom domain)
  // On web, uses same-origin /api/uploadSignedContract to avoid CORS preflight 403.
  static Future<String> uploadSignedContract({
    required String facilityId,
    required String contractId,
    required Uint8List pdfData,
    String? signingToken,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Uploading signed contract PDF via Cloud Function: $contractId');
      }

      final pdfBase64 = base64Encode(pdfData);
      final Map<String, dynamic> payload = {
        'facilityId': facilityId,
        'contractId': contractId,
        'pdfBase64': pdfBase64,
        if (signingToken != null && signingToken.isNotEmpty) 'signingToken': signingToken,
      };

      String url;
      if (kIsWeb) {
        // Same-origin request avoids CORS preflight 403 (Hosting rewrite to uploadSignedContractHttp)
        final baseUrl = Uri.base.origin;
        final apiUrl = '$baseUrl/api/uploadSignedContract';
        final headers = <String, String>{
          'Content-Type': 'application/json',
        };
        final user = _auth.currentUser;
        if (user != null) {
          final token = await user.getIdToken();
          headers['Authorization'] = 'Bearer $token';
        }
        final response = await http.post(
          Uri.parse(apiUrl),
          headers: headers,
          body: jsonEncode({'data': payload}),
        );
        if (response.statusCode != 200) {
          final errBody = response.body;
          throw Exception('Upload failed: ${response.statusCode} $errBody');
        }
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final result = decoded['result'];
        url = result is String ? result : result.toString();
      } else {
        final callable = FirebaseFunctions.instance.httpsCallable('uploadSignedContract');
        final result = await callable.call<String>(payload);
        url = result.data ?? '';
      }

      if (url.isEmpty) {
        throw Exception('Invalid response from upload function');
      }

      if (kDebugMode) {
        print('✅ Signed contract uploaded successfully: $url');
      }

      return url;
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

      final ref = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contracts')
          .doc(contractId);
      final snap = await ref.get();
      final beforeData = snap.exists && snap.data() != null
          ? Map<String, dynamic>.from(snap.data()!)
          : null;

      await ref.delete();

      await AuditService.logEvent(
        facilityId: facilityId,
        eventType: 'contract.deleted',
        targetType: 'contract',
        targetId: contractId,
        tenantId: beforeData?['tenantId'] as String?,
        before: beforeData,
        metadata: {
          if (beforeData != null && beforeData['status'] != null)
            'status': beforeData['status'],
        },
      );

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

  // Upload contract file with compliance metadata.
  // On web, uses same-origin /api/uploadContractPdf to avoid CORS preflight 403.
  // [onProgress] optional: (bytesTransferred, totalBytes) for progress UI.
  static Future<String> uploadContractFile({
    required String facilityId,
    required String contractId,
    required Uint8List fileData,
    required String fileName,
    void Function(int bytesTransferred, int totalBytes)? onProgress,
    bool skipFirestoreUpdate = false,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Uploading contract file: $fileName');
      }

      final storagePath = 'facilities/$facilityId/contracts/$contractId/$fileName';
      String downloadUrl;

      if (kIsWeb) {
        // Same-origin request avoids CORS preflight 403 (Hosting rewrite to uploadContractPdfHttp)
        onProgress?.call(0, fileData.length);
        final baseUrl = Uri.base.origin;
        final apiUrl = '$baseUrl/api/uploadContractPdf';
        final headers = <String, String>{'Content-Type': 'application/json'};
        final token = await user.getIdToken();
        headers['Authorization'] = 'Bearer $token';
        final payload = {
          'facilityId': facilityId,
          'contractId': contractId,
          'fileName': fileName,
          'pdfBase64': base64Encode(fileData),
        };
        final response = await http.post(
          Uri.parse(apiUrl),
          headers: headers,
          body: jsonEncode({'data': payload}),
        );
        if (response.statusCode != 200) {
          throw Exception('Upload failed: ${response.statusCode} ${response.body}');
        }
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final result = decoded['result'];
        downloadUrl = result is String ? result : result.toString();
        onProgress?.call(fileData.length, fileData.length);
      } else {
        final ref = _storage.ref().child(storagePath);
        final uploadTask = ref.putData(
          fileData,
          SettableMetadata(contentType: 'application/pdf'),
        );
        final sub = uploadTask.snapshotEvents.listen((snapshot) {
          onProgress?.call(snapshot.bytesTransferred, snapshot.totalBytes);
        });
        try {
          final snapshot = await uploadTask;
          downloadUrl = await snapshot.ref.getDownloadURL();
        } finally {
          await sub.cancel();
        }
      }

      // Compute SHA-256 hash via Cloud Function (timeout so upload UI never hangs)
      String? documentSha256;
      try {
        final functions = FirebaseFunctions.instance;
        final callable = functions.httpsCallable('computeDocumentHash');
        final result = await callable
            .call({'fileData': fileData})
            .timeout(const Duration(seconds: 10));
        documentSha256 = result.data['sha256'] as String?;
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ Error computing hash (non-blocking): $e');
        }
      }

      if (!skipFirestoreUpdate) {
        await _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('contracts')
            .doc(contractId)
            .update({
          'fileUrl': downloadUrl,
          'fileSize': fileData.length,
          'contentType': 'application/pdf',
          'uploadedAt': FieldValue.serverTimestamp(),
          'storagePath': storagePath,
          if (documentSha256 != null) 'documentSha256': documentSha256,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

      if (kDebugMode) {
        print('✅ Contract file uploaded successfully: $downloadUrl');
        if (documentSha256 != null) {
          print('📝 Document SHA-256: $documentSha256');
        }
      }

      return downloadUrl;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error uploading contract file: $e');
      }
      rethrow;
    }
  }

  /// Generate a PDF from template content (markdown/text).
  /// Used when creating a contract from a template without an uploaded file.
  static Future<Uint8List> generatePdfFromTemplateContent({
    required String content,
    required String title,
  }) async {
    // Simple markdown-to-plain conversion for PDF rendering
    String plain(String s) {
      return s
          .replaceAll(RegExp(r'^#+\s*'), '')
          .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m.group(1)!)
          .replaceAllMapped(RegExp(r'\*(.+?)\*'), (m) => m.group(1)!)
          .replaceAll(RegExp(r'^-\s*'), '• ')
          .trim();
    }

    final paragraphs = content
        .split(RegExp(r'\n\s*\n'))
        .where((p) => p.trim().isNotEmpty)
        .map((p) => plain(p))
        .where((p) => p.isNotEmpty)
        .toList();

    if (paragraphs.isEmpty) {
      paragraphs.add('(No content)');
    }

    final pdf = pw.Document();
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(40),
        build: (pw.Context context) {
          return [
            pw.Header(
              level: 0,
              child: pw.Text(
                title,
                style: pw.TextStyle(
                  fontSize: 20,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            pw.SizedBox(height: 20),
            ...paragraphs.expand((p) => [
                  pw.Text(
                    p,
                    style: const pw.TextStyle(fontSize: 11),
                  ),
                  pw.SizedBox(height: 12),
                ]),
          ];
        },
      ),
    );
    return await pdf.save();
  }

  /// Disable a contract (prevents new envelopes from being created)
  static Future<void> disableContract({
    required String facilityId,
    required String contractId,
    required String reason,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Disabling contract: $contractId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contracts')
          .doc(contractId)
          .update({
        'complianceStatus': 'disabled',
        'disabledAt': FieldValue.serverTimestamp(),
        'disabledBy': user.uid,
        'disabledReason': reason,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (kDebugMode) {
        print('✅ Contract disabled successfully: $contractId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error disabling contract: $e');
      }
      rethrow;
    }
  }

  /// Enable a contract (re-enables for new envelopes)
  static Future<void> enableContract({
    required String facilityId,
    required String contractId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Enabling contract: $contractId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contracts')
          .doc(contractId)
          .update({
        'complianceStatus': 'active',
        'disabledAt': FieldValue.delete(),
        'disabledBy': FieldValue.delete(),
        'disabledReason': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (kDebugMode) {
        print('✅ Contract enabled successfully: $contractId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error enabling contract: $e');
      }
      rethrow;
    }
  }

  /// Check if a contract can be used for new envelopes (not disabled)
  static Future<bool> canUseContractForNewEnvelopes({
    required String facilityId,
    required String contractId,
  }) async {
    try {
      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contracts')
          .doc(contractId)
          .get();

      if (!doc.exists) {
        return false;
      }

      final data = doc.data();
      if (data == null) {
        return false;
      }

      final complianceStatus = data['complianceStatus'] as String?;
      return complianceStatus != 'disabled';
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error checking contract usability: $e');
      }
      return false;
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
    String? fileUrl,
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
        'facilityId': facilityId,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'createdBy': createdBy ?? user.uid,
        'isActive': true,
        if (fileUrl != null) 'fileUrl': fileUrl,
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
          .get();

      if (kDebugMode) {
        print('📄 Query returned ${querySnapshot.docs.length} template docs for facility: $facilityId');
      }

      final templates = <ContractTemplateModel>[];
      for (final doc in querySnapshot.docs) {
        try {
          final t = ContractTemplateModel.fromFirestore(doc);
          if (t.isActive) templates.add(t);
        } catch (parseErr) {
          if (kDebugMode) {
            print('⚠️ Error parsing template ${doc.id}: $parseErr');
          }
        }
      }
      templates.sort((a, b) => a.name.compareTo(b.name));

      if (kDebugMode) {
        print('✅ Successfully retrieved ${templates.length} contract templates for facility: $facilityId');
      }

      return templates;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting contract templates: $e');
      }
      rethrow;
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
    String? fileUrl,
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
      if (fileUrl != null) updateData['fileUrl'] = fileUrl;
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

  /// Disable a contract template (prevents new envelopes from being created)
  static Future<void> disableContractTemplate({
    required String facilityId,
    required String templateId,
    required String reason,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Disabling contract template: $templateId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contractTemplates')
          .doc(templateId)
          .update({
        'complianceStatus': 'disabled',
        'disabledAt': FieldValue.serverTimestamp(),
        'disabledBy': user.uid,
        'disabledReason': reason,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (kDebugMode) {
        print('✅ Contract template disabled successfully: $templateId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error disabling contract template: $e');
      }
      rethrow;
    }
  }

  /// Enable a contract template (re-enables for new envelopes)
  static Future<void> enableContractTemplate({
    required String facilityId,
    required String templateId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Enabling contract template: $templateId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contractTemplates')
          .doc(templateId)
          .update({
        'complianceStatus': 'active',
        'disabledAt': FieldValue.delete(),
        'disabledBy': FieldValue.delete(),
        'disabledReason': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (kDebugMode) {
        print('✅ Contract template enabled successfully: $templateId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error enabling contract template: $e');
      }
      rethrow;
    }
  }

  /// Check if a template can be used for new envelopes (not disabled)
  static Future<bool> canUseTemplateForNewEnvelopes({
    required String facilityId,
    required String templateId,
  }) async {
    try {
      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('contractTemplates')
          .doc(templateId)
          .get();

      if (!doc.exists) {
        return false;
      }

      final data = doc.data();
      if (data == null) {
        return false;
      }

      final complianceStatus = data['complianceStatus'] as String?;
      return complianceStatus != 'disabled';
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error checking template usability: $e');
      }
      return false;
    }
  }
}