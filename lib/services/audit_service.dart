import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class AuditService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  static Future<void> logDNRAction({
    required String facilityId,
    required String action, // 'dnr.create', 'dnr.toggle', 'dnr.override'
    required String targetId, // DNR entry ID
    Map<String, dynamic>? details,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      if (kDebugMode) {
        print('📝 Logging DNR audit: $action for $targetId in facility $facilityId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('auditLogs')
          .add({
        'action': action,
        'actorUid': user.uid,
        'actorEmail': user.email,
        'targetId': targetId,
        'details': details ?? {},
        'at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error logging DNR audit: $e');
      }
      // Don't throw - audit logging should not break the main flow
    }
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
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      if (kDebugMode) {
        print('📝 Logging ledger entry creation: $entryId for tenant $tenantId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('auditLogs')
          .add({
        'action': 'ledger.entry.created',
        'actorUid': user.uid,
        'actorEmail': user.email,
        'targetId': entryId,
        'entityType': 'ledgerEntry',
        'entityId': entryId,
        'tenantId': tenantId,
        'details': {
          'type': type,
          'amount': amount,
          ...?details,
        },
        'at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error logging ledger entry creation: $e');
      }
    }
  }

  /// Log ledger entry voiding
  static Future<void> logLedgerEntryVoided({
    required String facilityId,
    required String tenantId,
    required String entryId,
    String? reason,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      if (kDebugMode) {
        print('📝 Logging ledger entry void: $entryId for tenant $tenantId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('auditLogs')
          .add({
        'action': 'ledger.entry.voided',
        'actorUid': user.uid,
        'actorEmail': user.email,
        'targetId': entryId,
        'entityType': 'ledgerEntry',
        'entityId': entryId,
        'tenantId': tenantId,
        'details': {
          if (reason != null) 'reason': reason,
        },
        'at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error logging ledger entry void: $e');
      }
    }
  }

  /// Log payment allocation
  static Future<void> logPaymentAllocated({
    required String facilityId,
    required String tenantId,
    required String paymentId,
    required List<Map<String, dynamic>> allocations,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      if (kDebugMode) {
        print('📝 Logging payment allocation: $paymentId for tenant $tenantId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('auditLogs')
          .add({
        'action': 'ledger.payment.allocated',
        'actorUid': user.uid,
        'actorEmail': user.email,
        'targetId': paymentId,
        'entityType': 'payment',
        'entityId': paymentId,
        'tenantId': tenantId,
        'details': {
          'allocations': allocations,
          'allocationCount': allocations.length,
        },
        'at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error logging payment allocation: $e');
      }
    }
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
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      if (kDebugMode) {
        print('📝 Logging move-in completion: tenant $tenantId, unit $unitId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('auditLogs')
          .add({
        'action': 'movein.completed',
        'actorUid': user.uid,
        'actorEmail': user.email,
        'targetId': tenantId,
        'entityType': 'moveIn',
        'entityId': contractId,
        'tenantId': tenantId,
        'details': {
          'unitId': unitId,
          'contractId': contractId,
          'totalAmount': totalAmount,
          ...?details,
        },
        'at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error logging move-in completion: $e');
      }
    }
  }

  /// Log contact log creation
  static Future<void> logContactLogCreated({
    required String facilityId,
    required String tenantId,
    required String logId,
    required String type,
    Map<String, dynamic>? details,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      if (kDebugMode) {
        print('📝 Logging contact log creation: $logId for tenant $tenantId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('auditLogs')
          .add({
        'action': 'contactlog.created',
        'actorUid': user.uid,
        'actorEmail': user.email,
        'targetId': logId,
        'entityType': 'contactLog',
        'entityId': logId,
        'tenantId': tenantId,
        'details': {
          'type': type,
          ...?details,
        },
        'at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error logging contact log creation: $e');
      }
    }
  }

  /// Log payment method creation
  static Future<void> logPaymentMethodCreated({
    required String facilityId,
    required String tenantId,
    required String methodId,
    required String type,
    Map<String, dynamic>? details,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      if (kDebugMode) {
        print('📝 Logging payment method creation: $methodId for tenant $tenantId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('auditLogs')
          .add({
        'action': 'paymentmethod.created',
        'actorUid': user.uid,
        'actorEmail': user.email,
        'targetId': methodId,
        'entityType': 'paymentMethod',
        'entityId': methodId,
        'tenantId': tenantId,
        'details': {
          'type': type,
          ...?details,
        },
        'at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error logging payment method creation: $e');
      }
    }
  }

  /// Log payment method deletion
  static Future<void> logPaymentMethodDeleted({
    required String facilityId,
    required String tenantId,
    required String methodId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      if (kDebugMode) {
        print('📝 Logging payment method deletion: $methodId for tenant $tenantId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('auditLogs')
          .add({
        'action': 'paymentmethod.deleted',
        'actorUid': user.uid,
        'actorEmail': user.email,
        'targetId': methodId,
        'entityType': 'paymentMethod',
        'entityId': methodId,
        'tenantId': tenantId,
        'at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error logging payment method deletion: $e');
      }
    }
  }

  /// Log autopay toggle
  static Future<void> logAutopayToggled({
    required String facilityId,
    required String tenantId,
    required String methodId,
    required bool enabled,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      if (kDebugMode) {
        print('📝 Logging autopay toggle: $methodId for tenant $tenantId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('auditLogs')
          .add({
        'action': 'autopay.${enabled ? 'enabled' : 'disabled'}',
        'actorUid': user.uid,
        'actorEmail': user.email,
        'targetId': methodId,
        'entityType': 'paymentMethod',
        'entityId': methodId,
        'tenantId': tenantId,
        'details': {
          'enabled': enabled,
        },
        'at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error logging autopay toggle: $e');
      }
    }
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
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      if (kDebugMode) {
        print('📝 Logging autopay processed: $methodId for tenant $tenantId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('auditLogs')
          .add({
        'action': 'autopay.processed',
        'actorUid': user.uid,
        'actorEmail': user.email,
        'targetId': methodId,
        'entityType': 'paymentMethod',
        'entityId': methodId,
        'tenantId': tenantId,
        'details': {
          'amount': amount,
          if (transactionId != null) 'transactionId': transactionId,
          ...?details,
        },
        'at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error logging autopay processed: $e');
      }
    }
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
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      if (kDebugMode) {
        print('📝 Logging move-out completion: tenant $tenantId, unit $unitId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('auditLogs')
          .add({
        'action': 'moveout.completed',
        'actorUid': user.uid,
        'actorEmail': user.email,
        'targetId': tenantId,
        'entityType': 'moveOut',
        'entityId': contractId,
        'tenantId': tenantId,
        'details': {
          'unitId': unitId,
          'contractId': contractId,
          'charges': charges,
          'refund': refund,
          ...?details,
        },
        'at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error logging move-out completion: $e');
      }
    }
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
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      if (kDebugMode) {
        print('📝 Logging invoice creation: $invoiceId for tenant $tenantId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('auditLogs')
          .add({
        'action': 'invoice.created',
        'actorUid': user.uid,
        'actorEmail': user.email,
        'targetId': invoiceId,
        'entityType': 'invoice',
        'entityId': invoiceId,
        'tenantId': tenantId,
        'details': {
          'invoiceNumber': invoiceNumber,
          'total': total,
          ...?details,
        },
        'at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error logging invoice creation: $e');
      }
    }
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
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      if (kDebugMode) {
        print('📝 Logging invoice action: invoice.$action for $invoiceId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('auditLogs')
          .add({
        'action': 'invoice.$action',
        'actorUid': user.uid,
        'actorEmail': user.email,
        'targetId': invoiceId,
        'entityType': 'invoice',
        'entityId': invoiceId,
        'tenantId': tenantId,
        'details': {
          'invoiceNumber': invoiceNumber,
          ...?details,
        },
        'at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error logging invoice action: $e');
      }
    }
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
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      if (kDebugMode) {
        print('📝 Logging transfer completion: $transferId for tenant $tenantId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('auditLogs')
          .add({
        'action': 'transfer.completed',
        'actorUid': user.uid,
        'actorEmail': user.email,
        'targetId': transferId,
        'entityType': 'transfer',
        'entityId': transferId,
        'tenantId': tenantId,
        'details': {
          'fromUnitNumber': fromUnitNumber,
          'toUnitNumber': toUnitNumber,
          'netAmount': netAmount,
          ...?details,
        },
        'at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error logging transfer completion: $e');
      }
    }
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
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      if (kDebugMode) {
        print('📝 Logging document upload: $documentId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('auditLogs')
          .add({
        'action': 'document.uploaded',
        'actorUid': user.uid,
        'actorEmail': user.email,
        'targetId': documentId,
        'entityType': 'document',
        'entityId': documentId,
        'tenantId': tenantId,
        'details': {
          'fileName': fileName,
          'documentType': documentType,
          ...?details,
        },
        'at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error logging document upload: $e');
      }
    }
  }

  /// Log document deletion
  static Future<void> logDocumentDeleted({
    required String facilityId,
    required String documentId,
    required String fileName,
    Map<String, dynamic>? details,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      if (kDebugMode) {
        print('📝 Logging document deletion: $documentId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('auditLogs')
          .add({
        'action': 'document.deleted',
        'actorUid': user.uid,
        'actorEmail': user.email,
        'targetId': documentId,
        'entityType': 'document',
        'entityId': documentId,
        'details': {
          'fileName': fileName,
          ...?details,
        },
        'at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error logging document deletion: $e');
      }
    }
  }

  /// Log lien creation
  static Future<void> logLienCreated({
    required String facilityId,
    required String lienId,
    required String tenantId,
    required String unitId,
    Map<String, dynamic>? details,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      if (kDebugMode) {
        print('📝 Logging lien creation: $lienId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('auditLogs')
          .add({
        'action': 'lien.created',
        'actorUid': user.uid,
        'actorEmail': user.email,
        'targetId': lienId,
        'entityType': 'lien',
        'entityId': lienId,
        'tenantId': tenantId,
        'unitId': unitId,
        'details': details ?? {},
        'at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error logging lien creation: $e');
      }
    }
  }
}
