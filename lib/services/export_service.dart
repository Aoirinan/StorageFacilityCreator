import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/export_job_model.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/services/permission_service.dart';

/// Service for exporting data to CSV
class ExportService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final FirebaseFunctions _functions = FirebaseFunctions.instance;

  /// Create an export job (for large datasets, uses Cloud Function)
  static Future<String> createExportJob({
    required String facilityId,
    required ExportType type,
    Map<String, dynamic>? filters,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      // Check export permission
      final permissionCheck = await PermissionService.hasPermission(
        facilityId: facilityId,
        permission: PermissionType.exportData,
      );

      if (!permissionCheck.hasPermission) {
        throw Exception(permissionCheck.reason ??
            'You do not have permission to export data');
      }

      // Create export job document
      final jobRef = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('exportJobs')
          .doc();

      final jobData = {
        'facilityId': facilityId,
        'type': type.name,
        'status': ExportStatus.pending.name,
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': user.uid,
        if (filters != null) 'filters': filters,
      };

      await jobRef.set(jobData);

      // Trigger Cloud Function for processing
      final exportFunction = _functions.httpsCallable('processExportJob');
      await exportFunction.call({
        'facilityId': facilityId,
        'jobId': jobRef.id,
        'type': type.name,
        'filters': filters,
      });

      return jobRef.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating export job: $e');
      }
      rethrow;
    }
  }

  /// Export tenants to CSV (client-side, for small datasets)
  static Future<String> exportTenantsToCSV({
    required String facilityId,
    DateTime? startDate,
    DateTime? endDate,
    bool? isActive,
  }) async {
    try {
      // Check export permission
      final permissionCheck = await PermissionService.hasPermission(
        facilityId: facilityId,
        permission: PermissionType.exportData,
      );

      if (!permissionCheck.hasPermission) {
        throw Exception(permissionCheck.reason ??
            'You do not have permission to export data');
      }
      Query<Map<String, dynamic>> query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants');

      if (isActive != null) {
        query = query.where('isActive', isEqualTo: isActive);
      }

      if (startDate != null) {
        query = query.where('createdAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(startDate));
      }

      if (endDate != null) {
        query = query.where('createdAt',
            isLessThanOrEqualTo: Timestamp.fromDate(endDate));
      }

      final snapshot = await query.get();

      // Build CSV
      final csvRows = <String>[];

      // Header
      csvRows.add(
          'ID,Name,Email,Phone,Unit Number,Monthly Rate,Status,Created At,Notes');

      // Data rows
      for (final doc in snapshot.docs) {
        final data = doc.data();
        csvRows.add([
          doc.id,
          _escapeCsvField(data['name'] as String? ?? ''),
          _escapeCsvField(data['email'] as String? ?? ''),
          _escapeCsvField(data['phone'] as String? ?? ''),
          _escapeCsvField(data['unitNumber'] as String? ?? ''),
          (data['monthlyRate'] as num?)?.toString() ?? '0',
          (data['isActive'] as bool?) == true ? 'Active' : 'Inactive',
          data['createdAt'] != null
              ? (data['createdAt'] as Timestamp).toDate().toIso8601String()
              : '',
          _escapeCsvField(data['notes'] as String? ?? ''),
        ].join(','));
      }

      return csvRows.join('\n');
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error exporting tenants: $e');
      }
      rethrow;
    }
  }

  /// Export payments to CSV (client-side, for small datasets)
  static Future<String> exportPaymentsToCSV({
    required String facilityId,
    DateTime? startDate,
    DateTime? endDate,
    PaymentStatus? status,
  }) async {
    try {
      // Check export permission
      final permissionCheck = await PermissionService.hasPermission(
        facilityId: facilityId,
        permission: PermissionType.exportData,
      );

      if (!permissionCheck.hasPermission) {
        throw Exception(permissionCheck.reason ??
            'You do not have permission to export data');
      }
      Query<Map<String, dynamic>> query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('payments')
          .where('isActive', isEqualTo: true);

      if (status != null) {
        query = query.where('status', isEqualTo: status.name);
      }

      if (startDate != null) {
        query = query.where('createdAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(startDate));
      }

      if (endDate != null) {
        query = query.where('createdAt',
            isLessThanOrEqualTo: Timestamp.fromDate(endDate));
      }

      final snapshot = await query.get();

      // Build CSV
      final csvRows = <String>[];

      // Header
      csvRows.add(
          'ID,Tenant ID,Amount,Status,Method,Due Date,Paid Date,Transaction ID,Created At');

      // Data rows
      for (final doc in snapshot.docs) {
        final data = doc.data();
        csvRows.add([
          doc.id,
          _escapeCsvField(data['tenantId'] as String? ?? ''),
          (data['amount'] as num?)?.toString() ?? '0',
          _escapeCsvField(data['status'] as String? ?? ''),
          _escapeCsvField(data['method'] as String? ?? ''),
          data['dueDate'] != null
              ? (data['dueDate'] as Timestamp).toDate().toIso8601String()
              : '',
          data['paidDate'] != null || data['paidAt'] != null
              ? ((data['paidDate'] ?? data['paidAt']) as Timestamp)
                  .toDate()
                  .toIso8601String()
              : '',
          _escapeCsvField(data['transactionId'] as String? ??
              data['externalPaymentId'] as String? ??
              ''),
          data['createdAt'] != null
              ? (data['createdAt'] as Timestamp).toDate().toIso8601String()
              : '',
        ].join(','));
      }

      return csvRows.join('\n');
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error exporting payments: $e');
      }
      rethrow;
    }
  }

  /// Export audit logs to CSV (client-side, for small datasets)
  static Future<String> exportAuditLogsToCSV({
    required String facilityId,
    DateTime? startDate,
    DateTime? endDate,
    String? eventType,
  }) async {
    try {
      // Check export permission
      final permissionCheck = await PermissionService.hasPermission(
        facilityId: facilityId,
        permission: PermissionType.exportData,
      );

      if (!permissionCheck.hasPermission) {
        throw Exception(permissionCheck.reason ??
            'You do not have permission to export data');
      }
      Query<Map<String, dynamic>> query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('auditLogs')
          .orderBy('timestamp', descending: true);

      if (eventType != null) {
        query = query.where('eventType', isEqualTo: eventType);
      }

      if (startDate != null) {
        query = query.where('timestamp',
            isGreaterThanOrEqualTo: Timestamp.fromDate(startDate));
      }

      if (endDate != null) {
        query = query.where('timestamp',
            isLessThanOrEqualTo: Timestamp.fromDate(endDate));
      }

      final snapshot =
          await query.limit(10000).get(); // Limit to 10k for client-side

      // Build CSV
      final csvRows = <String>[];

      // Header
      csvRows.add(
          'ID,Event Type,Actor Email,Actor Role,Target Type,Target ID,Tenant ID,Timestamp,Metadata');

      // Data rows
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final metadata = data['metadata'] as Map<String, dynamic>?;
        csvRows.add([
          doc.id,
          _escapeCsvField(data['eventType'] as String? ?? ''),
          _escapeCsvField(data['actorEmail'] as String? ?? ''),
          _escapeCsvField(data['actorRole'] as String? ?? ''),
          _escapeCsvField(data['targetType'] as String? ?? ''),
          _escapeCsvField(data['targetId'] as String? ?? ''),
          _escapeCsvField(data['tenantId'] as String? ?? ''),
          data['timestamp'] != null
              ? (data['timestamp'] as Timestamp).toDate().toIso8601String()
              : '',
          metadata != null ? _escapeCsvField(jsonEncode(metadata)) : '',
        ].join(','));
      }

      return csvRows.join('\n');
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error exporting audit logs: $e');
      }
      rethrow;
    }
  }

  /// Get export job status
  static Future<ExportJobModel?> getExportJob({
    required String facilityId,
    required String jobId,
  }) async {
    try {
      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('exportJobs')
          .doc(jobId)
          .get();

      if (!doc.exists) return null;

      return ExportJobModel.fromFirestore(doc);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting export job: $e');
      }
      return null;
    }
  }

  /// Get all export jobs for a facility
  static Stream<List<ExportJobModel>> getExportJobsStream(String facilityId) {
    return _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('exportJobs')
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => ExportJobModel.fromFirestore(doc))
            .toList());
  }

  /// Request a short-lived signed URL for a completed export.
  static Future<Uri> getExportDownloadUrl({
    required String facilityId,
    required String jobId,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('User not authenticated');

    final callable = _functions.httpsCallable('getExportDownloadUrl');
    final result = await callable.call({
      'facilityId': facilityId,
      'jobId': jobId,
    });
    final data = result.data as Map<Object?, Object?>;
    final downloadUrl = data['downloadUrl'];

    if (downloadUrl is! String) {
      throw Exception('Export download URL was not returned');
    }

    final uri = Uri.tryParse(downloadUrl);
    if (uri == null || !uri.hasScheme) {
      throw Exception('Export download URL is invalid');
    }
    return uri;
  }

  /// Escape CSV field (handles commas, quotes, newlines)
  static String _escapeCsvField(String field) {
    if (field.contains(',') || field.contains('"') || field.contains('\n')) {
      return '"${field.replaceAll('"', '""')}"';
    }
    return field;
  }

  /// Download CSV as blob (for web)
  static void downloadCSV(String csvContent, String filename) {
    // This will be handled by the UI layer
    // The service just returns the CSV string
  }
}
