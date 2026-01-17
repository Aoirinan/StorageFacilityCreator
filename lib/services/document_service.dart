import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:sfcapp/models/document_attachment_model.dart';
import 'package:sfcapp/services/audit_service.dart';

/// Service for managing document attachments
class DocumentService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseStorage _storage = FirebaseStorage.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  // Note: uploadDocument method removed - using uploadDocumentFromPicker for all platforms
  // This ensures consistent behavior across web and mobile

  /// Upload document from web file picker
  static Future<DocumentAttachment> uploadDocumentFromPicker({
    required String facilityId,
    required DocumentType documentType,
    required DocumentCategory category,
    String? tenantId,
    String? unitId,
    String? contractId,
    String? paymentId,
    String? invoiceId,
    String? lienId,
    String? description,
    DateTime? expiresAt,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) {
        throw Exception('No file selected');
      }

      final platformFile = result.files.first;
      
      // For web, we need to handle bytes differently
      if (kIsWeb) {
        // Web file handling
        if (platformFile.bytes == null) {
          throw Exception('File bytes are null');
        }
        
        // Upload bytes directly to Firebase Storage
        final fileName = platformFile.name;
        final fileSize = platformFile.size;
        final mimeType = platformFile.extension != null
            ? _getMimeTypeFromExtension(platformFile.extension!)
            : 'application/octet-stream';

        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final storagePath = 'facilities/$facilityId/documents/$timestamp/$fileName';

        final ref = _storage.ref().child(storagePath);
        final uploadTask = ref.putData(
          platformFile.bytes!,
          SettableMetadata(contentType: mimeType),
        );
        final snapshot = await uploadTask;
        final downloadUrl = await snapshot.ref.getDownloadURL();

        // Create document record
        final doc = DocumentAttachment(
          id: '',
          facilityId: facilityId,
          tenantId: tenantId,
          unitId: unitId,
          contractId: contractId,
          paymentId: paymentId,
          invoiceId: invoiceId,
          lienId: lienId,
          fileName: fileName,
          fileUrl: downloadUrl,
          filePath: storagePath,
          fileSize: fileSize,
          mimeType: mimeType,
          documentType: documentType,
          category: category,
          description: description,
          uploadedAt: DateTime.now(),
          uploadedBy: _auth.currentUser!.uid,
          uploadedByName: _auth.currentUser!.displayName ?? _auth.currentUser!.email,
          expiresAt: expiresAt,
          metadata: metadata,
        );

        final docRef = await _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('documents')
            .add(doc.toFirestore());

        final createdDoc = doc.copyWith(id: docRef.id);

        // Audit log
        await AuditService.logDocumentUploaded(
          facilityId: facilityId,
          documentId: docRef.id,
          fileName: fileName,
          documentType: documentType.name,
          tenantId: tenantId,
        );

        return createdDoc;
      } else {
        // Mobile file handling - use bytes if available, otherwise throw
        if (platformFile.bytes == null) {
          throw Exception('File bytes are null - mobile file handling not yet implemented');
        }
        
        // Use same web logic for mobile (bytes-based)
        final fileName = platformFile.name;
        final fileSize = platformFile.size;
        final mimeType = platformFile.extension != null
            ? _getMimeTypeFromExtension(platformFile.extension!)
            : 'application/octet-stream';

        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final storagePath = 'facilities/$facilityId/documents/$timestamp/$fileName';

        final ref = _storage.ref().child(storagePath);
        final uploadTask = ref.putData(
          platformFile.bytes!,
          SettableMetadata(contentType: mimeType),
        );
        final snapshot = await uploadTask;
        final downloadUrl = await snapshot.ref.getDownloadURL();

        // Create document record
        final doc = DocumentAttachment(
          id: '',
          facilityId: facilityId,
          tenantId: tenantId,
          unitId: unitId,
          contractId: contractId,
          paymentId: paymentId,
          invoiceId: invoiceId,
          lienId: lienId,
          fileName: fileName,
          fileUrl: downloadUrl,
          filePath: storagePath,
          fileSize: fileSize,
          mimeType: mimeType,
          documentType: documentType,
          category: category,
          description: description,
          uploadedAt: DateTime.now(),
          uploadedBy: _auth.currentUser!.uid,
          uploadedByName: _auth.currentUser!.displayName ?? _auth.currentUser!.email,
          expiresAt: expiresAt,
          metadata: metadata,
        );

        final docRef = await _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('documents')
            .add(doc.toFirestore());

        final createdDoc = doc.copyWith(id: docRef.id);

        // Audit log
        await AuditService.logDocumentUploaded(
          facilityId: facilityId,
          documentId: docRef.id,
          fileName: fileName,
          documentType: documentType.name,
          tenantId: tenantId,
        );

        return createdDoc;
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Document] Error uploading document from picker: $e');
      }
      rethrow;
    }
  }

  /// Get documents for a facility
  static Stream<List<DocumentAttachment>> getDocumentsForFacilityStream(
    String facilityId, {
    String? tenantId,
    String? category,
    DocumentType? documentType,
  }) {
    Query query = _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('documents')
        .where('isActive', isEqualTo: true);

    if (tenantId != null) {
      query = query.where('tenantId', isEqualTo: tenantId);
    }

    if (category != null) {
      query = query.where('category', isEqualTo: category);
    }

    if (documentType != null) {
      query = query.where('documentType', isEqualTo: documentType.name);
    }

    return query
        .orderBy('uploadedAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => DocumentAttachment.fromFirestore(doc))
            .toList());
  }

  /// Get documents for a tenant
  static Stream<List<DocumentAttachment>> getDocumentsForTenantStream({
    required String facilityId,
    required String tenantId,
  }) {
    return _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('documents')
        .where('tenantId', isEqualTo: tenantId)
        .where('isActive', isEqualTo: true)
        .orderBy('uploadedAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => DocumentAttachment.fromFirestore(doc))
            .toList());
  }

  /// Delete a document
  static Future<void> deleteDocument({
    required String facilityId,
    required String documentId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      // Get document to get file path
      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('documents')
          .doc(documentId)
          .get();

      if (!doc.exists) {
        throw Exception('Document not found');
      }

      final data = doc.data()!;
      final filePath = data['filePath'] as String?;

      // Delete from Firestore (soft delete)
      await doc.reference.update({
        'isActive': false,
        'deletedAt': FieldValue.serverTimestamp(),
        'deletedBy': user.uid,
      });

      // Delete from Storage if path exists
      if (filePath != null && filePath.isNotEmpty) {
        try {
          await _storage.ref().child(filePath).delete();
          if (kDebugMode) {
            print('✅ [Document] Deleted file from storage: $filePath');
          }
        } catch (e) {
          if (kDebugMode) {
            print('⚠️ [Document] Error deleting file from storage: $e');
          }
          // Continue even if storage delete fails
        }
      }

      // Audit log
      await AuditService.logDocumentDeleted(
        facilityId: facilityId,
        documentId: documentId,
        fileName: data['fileName'] as String? ?? 'Unknown',
      );

      if (kDebugMode) {
        print('✅ [Document] Deleted document: $documentId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Document] Error deleting document: $e');
      }
      rethrow;
    }
  }

  /// Get document by ID
  static Future<DocumentAttachment?> getDocument({
    required String facilityId,
    required String documentId,
  }) async {
    try {
      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('documents')
          .doc(documentId)
          .get();

      if (!doc.exists) return null;

      return DocumentAttachment.fromFirestore(doc);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Document] Error getting document: $e');
      }
      rethrow;
    }
  }

  static String _getMimeType(String fileName) {
    final extension = fileName.split('.').last.toLowerCase();
    return _getMimeTypeFromExtension(extension);
  }

  static String _getMimeTypeFromExtension(String extension) {
    switch (extension.toLowerCase()) {
      case 'pdf':
        return 'application/pdf';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      default:
        return 'application/octet-stream';
    }
  }
}

