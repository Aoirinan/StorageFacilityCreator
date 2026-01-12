import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/payment_model.dart';
import '../models/contract_model.dart';
import '../models/tenant_model.dart';
import '../models/ledger_entry_model.dart';
import '../services/email_service.dart';
import '../services/ledger_service.dart';

class PaymentService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  
  // Mock Square API configuration
  static const String _mockSquareApiKey = 'mock_square_api_key';
  static const String _mockSquareEnvironment = 'sandbox'; // or 'production'
  
  // Create a new payment
  static Future<PaymentModel> createPayment({
    required String tenantId,
    required String facilityId,
    required String contractId,
    required double amount,
    required PaymentMethod method,
    required DateTime dueDate,
    String? notes,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');
      
      final ref = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('payments')
          .doc();
      
      final now = DateTime.now();
      
      final paymentData = {
        'tenantId': tenantId,
        'facilityId': facilityId,
        'contractId': contractId,
        'amount': amount,
        'status': 'pending',
        'method': method.name,
        'dueDate': Timestamp.fromDate(dueDate),
        'paidAt': null,
        'notes': notes,
        'metadata': metadata,
        'createdAt': Timestamp.fromDate(now),
        'updatedAt': Timestamp.fromDate(now),
        'createdBy': user.uid,
        'isActive': true,
      };

      await ref.set(paymentData);

      final payment = PaymentModel(
        id: ref.id,
        tenantId: tenantId,
        facilityId: facilityId,
        contractId: contractId,
        amount: amount,
        status: PaymentStatus.pending,
        method: method,
        dueDate: dueDate,
        notes: notes,
        metadata: metadata,
        createdAt: now,
        updatedAt: now,
        createdBy: user.uid,
        isActive: true,
      );

      // Create corresponding ledger entry
      try {
        await LedgerService.createLedgerEntry(
          tenantId: tenantId,
          facilityId: facilityId,
          type: LedgerEntryType.payment,
          amount: -amount, // Negative for payments
          description: 'Payment - ${method.displayName}${notes != null ? ': $notes' : ''}',
          referenceId: ref.id,
          entryDate: now,
          status: LedgerEntryStatus.pending, // Will be updated when payment is marked as paid
          metadata: {
            'paymentMethod': method.name,
            'paymentId': ref.id,
          },
        );
        if (kDebugMode) {
          print('✅ Ledger entry created for payment: ${ref.id}');
        }
      } catch (e) {
        // Don't fail payment creation if ledger entry fails
        if (kDebugMode) {
          print('⚠️ Error creating ledger entry for payment ${ref.id}: $e');
        }
      }

      if (kDebugMode) {
        print('✅ Payment created successfully: ${ref.id}');
      }

      return payment;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating payment: $e');
      }
      rethrow;
    }
  }

  // Get payments for a facility (real-time stream)
  static Stream<List<PaymentModel>> getPaymentsForFacilityStream(String facilityId) {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Setting up payments stream for facility: $facilityId');
      }

      Query query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('payments')
          .limit(500); // Limit to 500 payments per facility (safety limit)
      
      // Try ordered query, fall back to unordered if index is building
      try {
        query = query.orderBy('paidAt', descending: true);
      } catch (orderingError) {
        if (kDebugMode) {
          print('⚠️ Ordered query not available, using unordered: $orderingError');
        }
      }

      return query.snapshots().map((snapshot) {
        final payments = snapshot.docs.map((doc) {
          return PaymentModel.fromFirestore(doc);
        }).toList();

        // Sort in memory if we used fallback query
        payments.sort((a, b) {
          final aDate = a.paidDate ?? a.createdAt;
          final bDate = b.paidDate ?? b.createdAt;
          return bDate.compareTo(aDate);
        });

        if (kDebugMode) {
          print('📡 Stream update: ${payments.length} payments for facility: $facilityId');
        }

        return payments;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error setting up payments stream: $e');
      }
      rethrow;
    }
  }

  // Get payments for a facility
  static Future<List<PaymentModel>> getPaymentsForFacility(String facilityId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 Getting payments for facility: $facilityId');
      }

      // Try ordered query first, fall back to unordered if index is building
      QuerySnapshot snapshot;
      try {
        snapshot = await _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('payments')
            .orderBy('paidAt', descending: true)
            .limit(100) // Limit to last 100 payments for performance
            .get();
      } catch (orderingError) {
        if (orderingError.toString().contains('failed-precondition') && orderingError.toString().contains('index')) {
          if (kDebugMode) {
            print('📋 INDEX BUILDING: Using fallback unordered query for payments...');
          }
          // Fallback to unordered query
          snapshot = await _firestore
              .collection('facilities')
              .doc(facilityId)
              .collection('payments')
              .limit(100)
              .get();
        } else {
          rethrow;
        }
      }

      final payments = snapshot.docs
          .map((doc) => PaymentModel.fromFirestore(doc))
          .toList();
          
      // Sort in memory (needed for fallback queries)
      payments.sort((a, b) {
        final aDate = a.paidDate ?? a.createdAt;
        final bDate = b.paidDate ?? b.createdAt;
        return bDate.compareTo(aDate);
      });

      if (kDebugMode) {
        print('✅ Successfully retrieved ${payments.length} payments');
      }

      return payments;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting payments: $e');
      }
      return [];
    }
  }

  // Get a single payment by ID
  static Future<PaymentModel?> getPayment({
    required String facilityId,
    required String paymentId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('payments')
          .doc(paymentId)
          .get();

      if (!doc.exists) return null;

      return PaymentModel.fromFirestore(doc);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting payment: $e');
      }
      rethrow;
    }
  }

  // Get payments for a tenant
  static Future<List<PaymentModel>> getPaymentsForTenant(String facilityId, String tenantId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 Getting payments for tenant: $tenantId');
      }

      final querySnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('payments')
          .where('tenantId', isEqualTo: tenantId)
          .where('isActive', isEqualTo: true)
          .orderBy('createdAt', descending: true)
          .get();

      final payments = querySnapshot.docs
          .map((doc) => PaymentModel.fromFirestore(doc))
          .toList();

      if (kDebugMode) {
        print('✅ Successfully retrieved ${payments.length} payments for tenant');
      }

      return payments;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting tenant payments: $e');
      }
      return [];
    }
  }

  static Future<Map<String, dynamic>> getTenantPaymentSummary(String facilityId, String tenantId) async {
    final payments = await getPaymentsForTenant(facilityId, tenantId);

    double outstanding = 0;
    DateTime? nextDueDate;
    int pendingCount = 0;
    final recentPending = <PaymentModel>[];

    for (final payment in payments) {
      final isPaid = payment.status == PaymentStatus.paid || payment.status == PaymentStatus.completed;
      if (!isPaid) {
        outstanding += payment.amount;
        pendingCount += 1;
        if (payment.dueDate.isAfter(DateTime.now())) {
          if (nextDueDate == null || payment.dueDate.isBefore(nextDueDate!)) {
            nextDueDate = payment.dueDate;
          }
        }
        if (recentPending.length < 3) {
          recentPending.add(payment);
        }
      }
    }

    recentPending.sort((a, b) => a.dueDate.compareTo(b.dueDate));

    return {
      'outstanding': outstanding,
      'pendingCount': pendingCount,
      'nextDueDate': nextDueDate,
      'recentPending': recentPending,
    };
  }

  // Mark payment as paid
  static Future<void> markPaymentAsPaid({
    required String facilityId,
    required String paymentId,
    required PaymentMethod method,
    String? transactionId,
    String? notes,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 Marking payment as paid: $paymentId');
      }

      final now = DateTime.now();
      final nowTimestamp = Timestamp.fromDate(now);

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('payments')
          .doc(paymentId)
          .update({
        'status': 'paid',
        'method': method.name,
        'transactionId': transactionId,
        'paidDate': nowTimestamp,
        'paidAt': nowTimestamp,
        'paidBy': user.uid,
        'notes': notes,
        'updatedAt': nowTimestamp,
      });

      // Update tenant's paidThrough date
      await _updateTenantPaidThrough(facilityId, paymentId);

      // Send receipt email if payment method doesn't auto-email (Stripe/Square auto-email)
      if (method != PaymentMethod.stripe && method != PaymentMethod.square) {
        try {
          await _sendReceiptEmail(facilityId, paymentId);
        } catch (e) {
          // Don't fail payment if email fails
          if (kDebugMode) {
            print('⚠️ Failed to send receipt email: $e');
          }
        }
      }

      if (kDebugMode) {
        print('✅ Payment marked as paid successfully: $paymentId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error marking payment as paid: $e');
      }
      rethrow;
    }
  }

  // Mark tenant as paid (creates payment record and updates tenant)
  static Future<String> markTenantAsPaid({
    required String facilityId,
    required String tenantId,
    required double amount,
    PaymentMethod method = PaymentMethod.cash,
    String? notes,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 Marking tenant as paid: $tenantId');
      }

      // Get tenant information
      final tenantDoc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .get();

      if (!tenantDoc.exists) {
        throw Exception('Tenant not found');
      }

      final tenantData = tenantDoc.data()!;
      final tenantName = tenantData['name'] ?? 'Unknown';
      final unitNumber = tenantData['unitNumber'] ?? '';

      // Calculate new paidThrough date (end of current month)
      final now = DateTime.now();
      final endOfCurrentMonth = DateTime(now.year, now.month + 1, 0);

      // Create payment record
      final paymentRef = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('payments')
          .add({
        'tenantId': tenantId,
        'facilityId': facilityId,
        'tenantName': tenantName,
        'unitNumber': unitNumber,
        'amount': amount,
        'status': 'paid',
        'paidAt': FieldValue.serverTimestamp(),
        'paidDate': FieldValue.serverTimestamp(),
        'dueDate': Timestamp.fromDate(endOfCurrentMonth),
        'method': method.name,
        'notes': notes,
        'contractId': tenantData['contractId'] ?? '',
        'createdByUid': user.uid,
        'createdBy': user.uid,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'isActive': true,
      });

      // Update tenant's paidThrough date
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .update({
        'paidThrough': Timestamp.fromDate(endOfCurrentMonth),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Create ledger entry and allocate payment
      try {
        // Check if ledger entry already exists for this payment
        final ledgerEntries = await LedgerService.getLedgerEntries(
          tenantId: tenantId,
          facilityId: facilityId,
        );
        
        LedgerEntry? existingEntry;
        try {
          existingEntry = ledgerEntries.firstWhere(
            (e) => e.referenceId == paymentRef.id,
          );
        } catch (_) {
          existingEntry = null;
        }

        if (existingEntry == null) {
          // Create ledger entry for this payment
          await LedgerService.createLedgerEntry(
            tenantId: tenantId,
            facilityId: facilityId,
            type: LedgerEntryType.payment,
            amount: -amount, // Negative for payments
            description: 'Payment - ${method.displayName}${notes != null ? ': $notes' : ''}',
            referenceId: paymentRef.id,
            entryDate: now,
            status: LedgerEntryStatus.posted,
            metadata: {
              'paymentMethod': method.name,
              'paymentId': paymentRef.id,
            },
          );
        }

        // Allocate payment to oldest charges
        await LedgerService.allocatePayment(
          paymentId: paymentRef.id,
          tenantId: tenantId,
          facilityId: facilityId,
          paymentAmount: amount,
        );
      } catch (e) {
        // Don't fail payment marking if ledger fails
        if (kDebugMode) {
          print('⚠️ Error creating/updating ledger entry for payment ${paymentRef.id}: $e');
        }
      }

      if (kDebugMode) {
        print('✅ Tenant marked as paid successfully: $tenantId');
        print('✅ Payment record created: ${paymentRef.id}');
        print('✅ Tenant paidThrough updated to: $endOfCurrentMonth');
      }

      return paymentRef.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error marking tenant as paid: $e');
      }
      rethrow;
    }
  }

  // Helper method to update tenant's paidThrough date
  static Future<void> _updateTenantPaidThrough(String facilityId, String paymentId) async {
    try {
      // Get the payment to find the tenant
      final paymentDoc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('payments')
          .doc(paymentId)
          .get();

      if (!paymentDoc.exists) return;

      final paymentData = paymentDoc.data()!;
      final tenantId = paymentData['tenantId'] as String;
      final dueDate = (paymentData['dueDate'] as Timestamp).toDate();

      // Calculate paidThrough (end of current month)
      final now = DateTime.now();
      final endOfMonth = DateTime(now.year, now.month + 1, 0); // Last day of current month
      final paidThrough = dueDate.isAfter(endOfMonth) ? dueDate : endOfMonth;

      // Update tenant's paidThrough
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .update({
        'paidThrough': Timestamp.fromDate(paidThrough),
        'updatedAt': Timestamp.fromDate(DateTime.now()),
      });

      if (kDebugMode) {
        print('✅ Updated tenant paidThrough: $tenantId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Warning: Could not update tenant paidThrough: $e');
      }
      // Don't fail payment marking if tenant update fails
    }
  }

  // Get late payments for a facility
  static Future<List<PaymentModel>> getLatePayments(String facilityId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 Getting late payments for facility: $facilityId');
      }

      final now = DateTime.now();
      final querySnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('payments')
          .where('isActive', isEqualTo: true)
          .where('status', isEqualTo: 'pending')
          .where('dueDate', isLessThan: Timestamp.fromDate(now))
          .orderBy('dueDate', descending: true)
          .get();

      final payments = querySnapshot.docs
          .map((doc) => PaymentModel.fromFirestore(doc))
          .toList();

      if (kDebugMode) {
        print('✅ Found ${payments.length} late payments');
      }

      return payments;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting late payments: $e');
      }
      return [];
    }
  }

  // Archive payment (soft delete)
  static Future<void> archivePayment(String facilityId, String paymentId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 Archiving payment: $paymentId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('payments')
          .doc(paymentId)
          .update({
        'isActive': false,
        'archivedAt': Timestamp.fromDate(DateTime.now()),
        'archivedByUid': user.uid,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
      });

      if (kDebugMode) {
        print('✅ Payment archived successfully: $paymentId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error archiving payment: $e');
      }
      rethrow;
    }
  }

  // Delete payment (hard delete)
  static Future<void> deletePayment(String facilityId, String paymentId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 Deleting payment: $paymentId');
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('payments')
          .doc(paymentId)
          .delete();

      if (kDebugMode) {
        print('✅ Payment deleted successfully: $paymentId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error deleting payment: $e');
      }
      rethrow;
    }
  }

  // Get payment statistics for a facility
  static Future<Map<String, dynamic>> getPaymentStatistics(String facilityId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('🔄 Getting payment statistics for facility: $facilityId');
      }

      final payments = await getPaymentsForFacility(facilityId);
      
      final totalPayments = payments.length;
      final paidPayments = payments.where((p) => p.status == PaymentStatus.paid).length;
      final pendingPayments = payments.where((p) => p.status == PaymentStatus.pending).length;
      final latePayments = payments.where((p) => p.status == PaymentStatus.pending && p.dueDate.isBefore(DateTime.now())).length;
      
      final totalAmount = payments.fold(0.0, (sum, p) => sum + p.amount);
      final paidAmount = payments.where((p) => p.status == PaymentStatus.paid).fold(0.0, (sum, p) => sum + p.amount);
      final pendingAmount = payments.where((p) => p.status == PaymentStatus.pending).fold(0.0, (sum, p) => sum + p.amount);

      final statistics = {
        'totalPayments': totalPayments,
        'paidPayments': paidPayments,
        'pendingPayments': pendingPayments,
        'latePayments': latePayments,
        'totalAmount': totalAmount,
        'paidAmount': paidAmount,
        'pendingAmount': pendingAmount,
        'collectionRate': totalPayments > 0 ? (paidPayments / totalPayments) * 100 : 0.0,
      };

      if (kDebugMode) {
        print('✅ Payment statistics calculated: $statistics');
      }

      return statistics;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting payment statistics: $e');
      }
      return {};
    }
  }

  // Send receipt email after payment
  static Future<void> _sendReceiptEmail(String facilityId, String paymentId) async {
    try {
      // Get payment details
      final paymentDoc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('payments')
          .doc(paymentId)
          .get();

      if (!paymentDoc.exists) return;

      final paymentData = paymentDoc.data()!;
      final tenantId = paymentData['tenantId'] as String;
      final amount = (paymentData['amount'] as num).toDouble();
      final method = paymentData['method'] as String;
      final paidDate = paymentData['paidDate'] as Timestamp? ?? paymentData['paidAt'] as Timestamp?;

      // Get tenant details
      final tenantDoc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .get();

      if (!tenantDoc.exists) return;

      final tenantData = tenantDoc.data()!;
      final tenantEmail = tenantData['email'] as String?;
      final tenantName = tenantData['name'] as String? ?? 'Tenant';
      final unitNumber = tenantData['unitNumber'] as String? ?? '';

      if (tenantEmail == null || tenantEmail.isEmpty) {
        if (kDebugMode) {
          print('⚠️ Cannot send receipt: tenant has no email');
        }
        return;
      }

      // Get facility details
      final facilityDoc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .get();

      final facilityName = facilityDoc.exists
          ? (facilityDoc.data()?['name'] as String? ?? 'Storage Facility')
          : 'Storage Facility';

      // Format payment date
      final paymentDateStr = paidDate != null
          ? '${paidDate.toDate().month}/${paidDate.toDate().day}/${paidDate.toDate().year}'
          : DateTime.now().toString().split(' ')[0];

      // Create receipt email
      final subject = 'Payment Receipt - $facilityName';
      final html = '''
        <html>
          <body style="font-family: Arial, sans-serif; line-height: 1.6; color: #333;">
            <div style="max-width: 600px; margin: 0 auto; padding: 20px;">
              <h2 style="color: #2563eb;">Payment Receipt</h2>
              <p>Dear $tenantName,</p>
              <p>Thank you for your payment. This email confirms your payment has been received.</p>
              
              <div style="background-color: #f3f4f6; padding: 15px; border-radius: 8px; margin: 20px 0;">
                <h3 style="margin-top: 0;">Payment Details</h3>
                <p><strong>Facility:</strong> $facilityName</p>
                ${unitNumber.isNotEmpty ? '<p><strong>Unit:</strong> $unitNumber</p>' : ''}
                <p><strong>Amount:</strong> \$${amount.toStringAsFixed(2)}</p>
                <p><strong>Payment Method:</strong> ${method.replaceAll('_', ' ').split(' ').map((w) => w[0].toUpperCase() + w.substring(1)).join(' ')}</p>
                <p><strong>Payment Date:</strong> $paymentDateStr</p>
                <p><strong>Payment ID:</strong> $paymentId</p>
              </div>
              
              <p>If you have any questions about this payment, please contact us.</p>
              <p>Thank you,<br>$facilityName</p>
            </div>
          </body>
        </html>
      ''';

      // Send email
      final emailResult = await EmailService.sendEmail(
        to: tenantEmail,
        subject: subject,
        html: html,
        facilityId: facilityId,
      );

      if (emailResult.success) {
        if (kDebugMode) {
          print('✅ Receipt email sent successfully to $tenantEmail');
        }
      } else {
        if (kDebugMode) {
          print('⚠️ Failed to send receipt email: ${emailResult.error}');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error sending receipt email: $e');
      }
      // Don't throw - receipt email failure shouldn't block payment
    }
  }
}