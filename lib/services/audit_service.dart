import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Standardized audit log entry schema
class AuditLogEntry {
  final String eventType; // e.g., "tenant.created", "payment.charged"
  final String actorUid;
  final String? actorEmail;
  final String? actorRole; // "owner", "manager", "employee"
  final String targetType; // "tenant", "payment", "invoice", etc.
  final String targetId;
  final String facilityId;
  final String? tenantId; // If applicable
  final Map<String, dynamic>? before; // Snapshot before change
  final Map<String, dynamic>? after; // Snapshot after change
  final DateTime timestamp;
  final String? ipAddress;
  final String? userAgent;
  final Map<String, dynamic>? metadata; // Additional context

  AuditLogEntry({
    required this.eventType,
    required this.actorUid,
    this.actorEmail,
    this.actorRole,
    required this.targetType,
    required this.targetId,
    required this.facilityId,
    this.tenantId,
    this.before,
    this.after,
    required this.timestamp,
    this.ipAddress,
    this.userAgent,
    this.metadata,
  });

  Map<String, dynamic> toFirestore() {
    final changes = <String, dynamic>{
      if (before != null) 'before': before,
      if (after != null) 'after': after,
    };
    final meta = <String, dynamic>{
      ...?metadata,
      if (actorRole != null) 'actorRole': actorRole!,
    };

    return {
      // App UI (audit log screen)
      'eventType': eventType,
      'actorUid': actorUid,
      if (actorEmail != null) 'actorEmail': actorEmail,
      if (actorRole != null) 'actorRole': actorRole,
      'targetType': targetType,
      'targetId': targetId,
      'facilityId': facilityId,
      if (tenantId != null) 'tenantId': tenantId,
      if (before != null) 'before': before,
      if (after != null) 'after': after,
      'timestamp': Timestamp.fromDate(timestamp),
      if (ipAddress != null) 'ipAddress': ipAddress,
      if (userAgent != null) 'userAgent': userAgent,
      'metadata': meta,
      // Firestore rules (facilities/.../auditLogs) — hasAll + userId match
      'action': eventType,
      'entityType': targetType,
      'entityId': targetId,
      'userId': actorUid,
      'userEmail': actorEmail ?? '',
      'changes': changes,
    };
  }
}

class AuditService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// When set, [logEvent] hands each entry here instead of writing it, with
  /// the actor left blank. Tests have no Firebase app, so without this every
  /// logEvent call is silently dropped and cannot be checked.
  @visibleForTesting
  static void Function(AuditLogEntry entry)? recordForTesting;

  /// Standardized audit log method - all other methods should use this
  static Future<void> logEvent({
    required String facilityId,
    required String eventType,
    required String targetType,
    required String targetId,
    String? tenantId,
    String? actorRole,
    Map<String, dynamic>? before,
    Map<String, dynamic>? after,
    Map<String, dynamic>? metadata,
    String? ipAddress,
    String? userAgent,
  }) async {
    final record = recordForTesting;
    if (record != null) {
      record(AuditLogEntry(
        eventType: eventType,
        actorUid: '',
        actorRole: actorRole,
        targetType: targetType,
        targetId: targetId,
        facilityId: facilityId,
        tenantId: tenantId,
        before: before,
        after: after,
        timestamp: DateTime.now(),
        metadata: metadata,
      ));
      return;
    }
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      // Get user role if not provided
      String? role = actorRole;
      if (role == null) {
        // Try to determine role from facility
        try {
          final facilityDoc = await _firestore
              .collection('facilities')
              .doc(facilityId)
              .get();
          
          if (facilityDoc.exists) {
            final facilityData = facilityDoc.data();
            if (facilityData?['ownerUid'] == user.uid) {
              role = 'owner';
            } else if (facilityData?['roles']?[user.uid] != null) {
              role = facilityData!['roles'][user.uid] as String;
            } else if (facilityData?['managers']?[user.uid] == true) {
              role = 'manager';
            }
          }
        } catch (e) {
          // Role determination failed, continue without it
        }
      }

      final entry = AuditLogEntry(
        eventType: eventType,
        actorUid: user.uid,
        actorEmail: user.email,
        actorRole: role,
        targetType: targetType,
        targetId: targetId,
        facilityId: facilityId,
        tenantId: tenantId,
        before: before,
        after: after,
        timestamp: DateTime.now(),
        ipAddress: ipAddress,
        userAgent: userAgent,
        metadata: metadata,
      );

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('auditLogs')
          .add(entry.toFirestore());

      if (kDebugMode) {
        print('📝 [AuditService] Logged event: $eventType for $targetType:$targetId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ [AuditService] Error logging event: $e');
      }
      // Don't throw - audit logging should not break the main flow
    }
  }

  /// [targetId] is a DNR entry unless [targetType] says otherwise (the
  /// override screens pass the tenant being let through).
  static Future<void> logDNRAction({
    required String facilityId,
    required String action, // 'dnr.create', 'dnr.update', 'dnr.delete', 'dnr.toggle', 'dnr.override', 'dnr.global.*'
    required String targetId,
    String targetType = 'dnr',
    String? tenantId,
    Map<String, dynamic>? details,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: action,
      targetType: targetType,
      targetId: targetId,
      tenantId: tenantId,
      metadata: details,
    );
  }

  /// Log ledger entry creation
  static Future<void> logLedgerEntryCreated({
    required String facilityId,
    required String tenantId,
    required String entryId,
    required String type,
    required double amount,
    Map<String, dynamic>? details,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'ledger.entry.created',
      targetType: 'ledgerEntry',
      targetId: entryId,
      tenantId: tenantId,
      after: {
        'type': type,
        'amount': amount,
      },
      metadata: details,
    );
  }

  /// Log ledger entry voiding
  static Future<void> logLedgerEntryVoided({
    required String facilityId,
    required String tenantId,
    required String entryId,
    String? reason,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'ledger.entry.voided',
      targetType: 'ledgerEntry',
      targetId: entryId,
      tenantId: tenantId,
      metadata: {
        if (reason != null) 'reason': reason,
      },
    );
  }

  /// Log payment allocation
  static Future<void> logPaymentAllocated({
    required String facilityId,
    required String tenantId,
    required String paymentId,
    required List<Map<String, dynamic>> allocations,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'ledger.payment.allocated',
      targetType: 'payment',
      targetId: paymentId,
      tenantId: tenantId,
      after: {
        'allocations': allocations,
        'allocationCount': allocations.length,
      },
    );
  }

  /// Log move-in completion
  static Future<void> logMoveInCompleted({
    required String facilityId,
    required String tenantId,
    required String unitId,
    required String contractId,
    required double totalAmount,
    Map<String, dynamic>? details,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'movein.completed',
      targetType: 'moveIn',
      targetId: contractId,
      tenantId: tenantId,
      after: {
        'unitId': unitId,
        'contractId': contractId,
        'totalAmount': totalAmount,
      },
      metadata: details,
    );
  }

  /// Log contact log creation
  static Future<void> logContactLogCreated({
    required String facilityId,
    required String tenantId,
    required String logId,
    required String type,
    Map<String, dynamic>? details,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'contactlog.created',
      targetType: 'contactLog',
      targetId: logId,
      tenantId: tenantId,
      after: {
        'type': type,
      },
      metadata: details,
    );
  }

  /// Log payment method creation
  static Future<void> logPaymentMethodCreated({
    required String facilityId,
    required String tenantId,
    required String methodId,
    required String type,
    Map<String, dynamic>? details,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'paymentmethod.created',
      targetType: 'paymentMethod',
      targetId: methodId,
      tenantId: tenantId,
      after: {
        'type': type,
      },
      metadata: details,
    );
  }

  /// Log payment method deletion
  static Future<void> logPaymentMethodDeleted({
    required String facilityId,
    required String tenantId,
    required String methodId,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'paymentmethod.deleted',
      targetType: 'paymentMethod',
      targetId: methodId,
      tenantId: tenantId,
    );
  }

  /// Log autopay toggle
  static Future<void> logAutopayToggled({
    required String facilityId,
    required String tenantId,
    required String methodId,
    required bool enabled,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'autopay.${enabled ? 'enabled' : 'disabled'}',
      targetType: 'paymentMethod',
      targetId: methodId,
      tenantId: tenantId,
      after: {
        'enabled': enabled,
      },
    );
  }

  /// Log autopay processed
  static Future<void> logAutopayProcessed({
    required String facilityId,
    required String tenantId,
    required String methodId,
    required double amount,
    String? transactionId,
    Map<String, dynamic>? details,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'autopay.processed',
      targetType: 'paymentMethod',
      targetId: methodId,
      tenantId: tenantId,
      after: {
        'amount': amount,
        if (transactionId != null) 'transactionId': transactionId,
      },
      metadata: details,
    );
  }

  /// Log move-out completion
  static Future<void> logMoveOutCompleted({
    required String facilityId,
    required String tenantId,
    required String unitId,
    required String contractId,
    required double charges,
    required double refund,
    Map<String, dynamic>? details,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'moveout.completed',
      targetType: 'moveOut',
      targetId: contractId,
      tenantId: tenantId,
      after: {
        'unitId': unitId,
        'contractId': contractId,
        'charges': charges,
        'refund': refund,
      },
      metadata: details,
    );
  }

  /// Log recurring charge generation
  static Future<void> logRecurringChargeGenerated({
    required String facilityId,
    required String tenantId,
    required String entryId,
    required double amount,
    required String chargeType,
    Map<String, dynamic>? details,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      if (kDebugMode) {
        print('📝 Logging recurring charge generation: $entryId for tenant $tenantId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('auditLogs')
          .add({
        'action': 'recurringcharge.generated',
        'actorUid': user.uid,
        'actorEmail': user.email,
        'targetId': entryId,
        'entityType': 'ledgerEntry',
        'entityId': entryId,
        'tenantId': tenantId,
        'details': {
          'amount': amount,
          'chargeType': chargeType,
          ...?details,
        },
        'at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error logging recurring charge generation: $e');
      }
    }
  }

  /// Log invoice creation
  static Future<void> logInvoiceCreated({
    required String facilityId,
    required String tenantId,
    required String invoiceId,
    required String invoiceNumber,
    required double total,
    Map<String, dynamic>? details,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'invoice.created',
      targetType: 'invoice',
      targetId: invoiceId,
      tenantId: tenantId,
      after: {
        'invoiceNumber': invoiceNumber,
        'total': total,
      },
      metadata: details,
    );
  }

  /// Log invoice action (paid, voided, etc.)
  static Future<void> logInvoiceAction({
    required String facilityId,
    required String tenantId,
    required String invoiceId,
    required String invoiceNumber,
    required String action, // 'paid', 'voided', etc.
    Map<String, dynamic>? details,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'invoice.$action',
      targetType: 'invoice',
      targetId: invoiceId,
      tenantId: tenantId,
      metadata: {
        'invoiceNumber': invoiceNumber,
        ...?details,
      },
    );
  }

  /// Log transfer completion
  static Future<void> logTransferCompleted({
    required String facilityId,
    required String tenantId,
    required String transferId,
    required String fromUnitNumber,
    required String toUnitNumber,
    required double netAmount,
    Map<String, dynamic>? details,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'transfer.completed',
      targetType: 'transfer',
      targetId: transferId,
      tenantId: tenantId,
      after: {
        'fromUnitNumber': fromUnitNumber,
        'toUnitNumber': toUnitNumber,
        'netAmount': netAmount,
      },
      metadata: details,
    );
  }

  /// Log document upload
  static Future<void> logDocumentUploaded({
    required String facilityId,
    required String documentId,
    required String fileName,
    required String documentType,
    String? tenantId,
    Map<String, dynamic>? details,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'document.uploaded',
      targetType: 'document',
      targetId: documentId,
      tenantId: tenantId,
      after: {
        'fileName': fileName,
        'documentType': documentType,
      },
      metadata: details,
    );
  }

  /// Log document deletion
  static Future<void> logDocumentDeleted({
    required String facilityId,
    required String documentId,
    required String fileName,
    Map<String, dynamic>? details,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'document.deleted',
      targetType: 'document',
      targetId: documentId,
      metadata: {
        'fileName': fileName,
        ...?details,
      },
    );
  }

  /// Log lien creation
  static Future<void> logLienCreated({
    required String facilityId,
    required String lienId,
    required String tenantId,
    required String unitId,
    Map<String, dynamic>? details,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'lien.created',
      targetType: 'lien',
      targetId: lienId,
      tenantId: tenantId,
      after: {
        'unitId': unitId,
      },
      metadata: details,
    );
  }

  /// Log contract upload with compliance
  static Future<void> logContractUploaded({
    required String facilityId,
    required String contractId,
    required String fileName,
    bool isLicensedForm = false,
    String? documentSha256,
    Map<String, dynamic>? details,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'CONTRACT_UPLOADED',
      targetType: 'contract',
      targetId: contractId,
      metadata: {
        'fileName': fileName,
        'isLicensedForm': isLicensedForm,
        if (documentSha256 != null) 'documentSha256': documentSha256,
        ...?details,
      },
    );
  }

  /// Log rights attestation
  static Future<void> logRightsAttested({
    required String facilityId,
    required String documentId,
    required String documentType, // 'contract' or 'template'
    String? documentSha256,
    Map<String, dynamic>? details,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'RIGHTS_ATTESTED',
      targetType: documentType,
      targetId: documentId,
      metadata: {
        if (documentSha256 != null) 'documentSha256': documentSha256,
        ...?details,
      },
    );
  }

  /// Log contract/template disabled
  static Future<void> logContractDisabled({
    required String facilityId,
    required String documentId,
    required String documentType, // 'contract' or 'template'
    required String reason,
    Map<String, dynamic>? details,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'CONTRACT_DISABLED',
      targetType: documentType,
      targetId: documentId,
      metadata: {
        'reason': reason,
        ...?details,
      },
    );
  }

  /// Log template created/updated
  static Future<void> logTemplateCreated({
    required String facilityId,
    required String templateId,
    Map<String, dynamic>? details,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'TEMPLATE_CREATED',
      targetType: 'template',
      targetId: templateId,
      metadata: details,
    );
  }

  static Future<void> logTemplateUpdated({
    required String facilityId,
    required String templateId,
    Map<String, dynamic>? details,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'TEMPLATE_UPDATED',
      targetType: 'template',
      targetId: templateId,
      metadata: details,
    );
  }

  /// Log terms acceptance
  static Future<void> logTermsAccepted({
    required String facilityId,
    required String tosVersion,
    Map<String, dynamic>? details,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'TERMS_ACCEPTED',
      targetType: 'facility',
      targetId: facilityId,
      metadata: {
        'tosVersion': tosVersion,
        ...?details,
      },
    );
  }

  /// Log rights reconfirmation
  static Future<void> logRightsReconfirmed({
    required String facilityId,
    required String documentId,
    required String documentType, // 'contract' or 'template'
    Map<String, dynamic>? details,
  }) async {
    await logEvent(
      facilityId: facilityId,
      eventType: 'RIGHTS_RECONFIRMED',
      targetType: documentType,
      targetId: documentId,
      metadata: details,
    );
  }
}
