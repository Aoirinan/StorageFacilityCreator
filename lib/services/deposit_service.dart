import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/deposit_model.dart';
import 'package:sfcapp/models/payment_model.dart';

/// Service for managing deposits
class DepositService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Generate next deposit number for a facility
  /// Format: DEP-YYYY-XXX (e.g., DEP-2025-001)
  static Future<String> _generateDepositNumber(String facilityId) async {
    try {
      final year = DateTime.now().year;
      final prefix = 'DEP-$year-';

      // Get the last deposit number for this year
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('deposits')
          .where('depositNumber', isGreaterThanOrEqualTo: prefix)
          .where('depositNumber', isLessThan: 'DEP-${year + 1}-')
          .orderBy('depositNumber', descending: true)
          .limit(1)
          .get();

      int nextNumber = 1;
      if (snapshot.docs.isNotEmpty) {
        final lastNumber = snapshot.docs.first.data()['depositNumber'] as String;
        final lastNumStr = lastNumber.split('-').last;
        nextNumber = (int.tryParse(lastNumStr) ?? 0) + 1;
      }

      return '$prefix${nextNumber.toString().padLeft(3, '0')}';
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Deposit] Error generating deposit number: $e');
      }
      // Fallback to timestamp-based number
      return 'DEP-${DateTime.now().year}-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}';
    }
  }

  /// Create a new deposit
  static Future<DepositModel> createDeposit({
    required String facilityId,
    required DepositMethod method,
    required DateTime depositDate,
    required double totalAmount,
    List<String>? paymentIds,
    double? cashAmount,
    double? checkAmount,
    int? checkCount,
    double? creditCardAmount,
    double? achAmount,
    String? bankAccount,
    String? notes,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final depositNumber = await _generateDepositNumber(facilityId);

      final deposit = DepositModel(
        id: '', // Will be set by Firestore
        facilityId: facilityId,
        depositNumber: depositNumber,
        status: DepositStatus.pending,
        method: method,
        depositDate: depositDate,
        totalAmount: totalAmount,
        cashAmount: cashAmount,
        checkAmount: checkAmount,
        checkCount: checkCount,
        creditCardAmount: creditCardAmount,
        achAmount: achAmount,
        paymentIds: paymentIds ?? [],
        bankAccount: bankAccount,
        notes: notes,
        createdAt: DateTime.now(),
        createdBy: user.uid,
      );

      final docRef = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('deposits')
          .add(deposit.toFirestore());

      // Update payment records to link to deposit
      if (paymentIds != null && paymentIds.isNotEmpty) {
        final batch = _firestore.batch();
        for (final paymentId in paymentIds) {
          final paymentRef = _firestore
              .collection('facilities')
              .doc(facilityId)
              .collection('payments')
              .doc(paymentId);
          batch.update(paymentRef, {
            'depositId': docRef.id,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
        await batch.commit();
      }

      if (kDebugMode) {
        print('✅ [Deposit] Created deposit: $depositNumber');
      }

      return deposit.copyWith(id: docRef.id);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Deposit] Error creating deposit: $e');
      }
      rethrow;
    }
  }

  /// Get all deposits for a facility
  static Future<List<DepositModel>> getDepositsForFacility(String facilityId) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('deposits')
          .where('isActive', isEqualTo: true)
          .orderBy('depositDate', descending: true)
          .get();

      return snapshot.docs
          .map((doc) => DepositModel.fromFirestore(doc))
          .toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Deposit] Error getting deposits: $e');
      }
      rethrow;
    }
  }

  /// Get stream of deposits for a facility
  static Stream<List<DepositModel>> getDepositsForFacilityStream(String facilityId) {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      return _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('deposits')
          .where('isActive', isEqualTo: true)
          .orderBy('depositDate', descending: true)
          .snapshots()
          .map((snapshot) => snapshot.docs
              .map((doc) => DepositModel.fromFirestore(doc))
              .toList());
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Deposit] Error getting deposits stream: $e');
      }
      rethrow;
    }
  }

  /// Get deposit by ID
  static Future<DepositModel?> getDeposit({
    required String facilityId,
    required String depositId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('deposits')
          .doc(depositId)
          .get();

      if (!doc.exists) return null;

      return DepositModel.fromFirestore(doc);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Deposit] Error getting deposit: $e');
      }
      rethrow;
    }
  }

  /// Update deposit status
  static Future<void> updateDepositStatus({
    required String facilityId,
    required String depositId,
    required DepositStatus status,
    DateTime? bankDepositDate,
    String? referenceNumber,
    double? overShort,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final updates = <String, dynamic>{
        'status': status.name,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (bankDepositDate != null) {
        updates['bankDepositDate'] = Timestamp.fromDate(bankDepositDate);
      }
      if (referenceNumber != null) {
        updates['referenceNumber'] = referenceNumber;
      }
      if (overShort != null) {
        updates['overShort'] = overShort;
      }
      if (status == DepositStatus.reconciled) {
        updates['reconciledBy'] = user.uid;
        updates['reconciledAt'] = FieldValue.serverTimestamp();
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('deposits')
          .doc(depositId)
          .update(updates);

      if (kDebugMode) {
        print('✅ [Deposit] Updated deposit status: $depositId -> ${status.name}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Deposit] Error updating deposit status: $e');
      }
      rethrow;
    }
  }

  /// Get unreconciled deposits
  static Future<List<DepositModel>> getUnreconciledDeposits(String facilityId) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('deposits')
          .where('isActive', isEqualTo: true)
          .where('status', whereIn: [DepositStatus.pending.name, DepositStatus.deposited.name])
          .orderBy('depositDate', descending: true)
          .get();

      return snapshot.docs
          .map((doc) => DepositModel.fromFirestore(doc))
          .toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Deposit] Error getting unreconciled deposits: $e');
      }
      rethrow;
    }
  }

  /// Get payments available for deposit (not yet in a deposit)
  static Future<List<PaymentModel>> getPaymentsAvailableForDeposit({
    required String facilityId,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      Query query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('payments')
          .where('isActive', isEqualTo: true)
          .where('status', whereIn: ['paid', 'completed']);

      // Filter by date range if provided
      if (startDate != null) {
        query = query.where('paidDate', isGreaterThanOrEqualTo: Timestamp.fromDate(startDate));
      }
      if (endDate != null) {
        query = query.where('paidDate', isLessThanOrEqualTo: Timestamp.fromDate(endDate));
      }

      final snapshot = await query.get();

      // Filter out payments that are already in a deposit
      final depositsSnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('deposits')
          .where('isActive', isEqualTo: true)
          .get();

      final depositedPaymentIds = <String>{};
      for (final depositDoc in depositsSnapshot.docs) {
        final depositData = depositDoc.data();
        final paymentIds = List<String>.from(depositData['paymentIds'] ?? []);
        depositedPaymentIds.addAll(paymentIds);
      }

      final availablePayments = <PaymentModel>[];
      for (final doc in snapshot.docs) {
        if (!depositedPaymentIds.contains(doc.id)) {
          try {
            final payment = PaymentModel.fromFirestore(doc);
            availablePayments.add(payment);
          } catch (e) {
            if (kDebugMode) {
              print('⚠️ [Deposit] Error parsing payment ${doc.id}: $e');
            }
          }
        }
      }

      return availablePayments;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Deposit] Error getting payments for deposit: $e');
      }
      rethrow;
    }
  }
}

