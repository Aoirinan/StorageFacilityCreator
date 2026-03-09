import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// Result of payment reconciliation check
class PaymentReconciliationResult {
  final bool isReconciled;
  final String? discrepancy;
  final Map<String, dynamic>? firestorePayment;
  final Map<String, dynamic>? stripePayment;
  final String? recommendation;

  PaymentReconciliationResult({
    required this.isReconciled,
    this.discrepancy,
    this.firestorePayment,
    this.stripePayment,
    this.recommendation,
  });
}

/// Service for reconciling payments between Firestore and Stripe
class PaymentReconciliationService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseFunctions _functions = FirebaseFunctions.instance;

  /// Reconcile a single payment by paymentIntentId
  static Future<PaymentReconciliationResult> reconcilePayment({
    required String facilityId,
    required String paymentIntentId,
  }) async {
    try {
      // Get payment from Firestore
      final firestorePayments = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('payments')
          .where('externalPaymentId', isEqualTo: paymentIntentId)
          .where('isActive', isEqualTo: true)
          .limit(1)
          .get();

      if (firestorePayments.docs.isEmpty) {
        return PaymentReconciliationResult(
          isReconciled: false,
          discrepancy: 'Payment not found in Firestore',
          recommendation: 'Payment may need to be manually created in Firestore',
        );
      }

      final firestorePayment = firestorePayments.docs[0].data();
      firestorePayment['id'] = firestorePayments.docs[0].id;

      // Get payment from Stripe via Cloud Function
      final reconcileFunction = _functions.httpsCallable('reconcileStripePayment');
      final result = await reconcileFunction.call({
        'facilityId': facilityId,
        'paymentIntentId': paymentIntentId,
      });

      final stripeData = result.data as Map<String, dynamic>?;

      if (stripeData == null || stripeData['found'] != true) {
        return PaymentReconciliationResult(
          isReconciled: false,
          discrepancy: 'Payment not found in Stripe',
          firestorePayment: firestorePayment,
          recommendation: 'Payment may have been deleted in Stripe or paymentIntentId is incorrect',
        );
      }

      final stripePayment = stripeData['payment'] as Map<String, dynamic>?;

      if (stripePayment == null) {
        return PaymentReconciliationResult(
          isReconciled: false,
          discrepancy: 'Stripe payment data missing',
          firestorePayment: firestorePayment,
        );
      }

      // Compare amounts (Stripe uses cents, Firestore uses dollars)
      final firestoreAmount = (firestorePayment['amount'] as num?)?.toDouble() ?? 0.0;
      final stripeAmount = ((stripePayment['amount'] as num?)?.toInt() ?? 0) / 100.0;

      if ((firestoreAmount - stripeAmount).abs() > 0.01) {
        return PaymentReconciliationResult(
          isReconciled: false,
          discrepancy: 'Amount mismatch: Firestore=\$${firestoreAmount.toStringAsFixed(2)}, Stripe=\$${stripeAmount.toStringAsFixed(2)}',
          firestorePayment: firestorePayment,
          stripePayment: stripePayment,
          recommendation: 'Amounts do not match. Verify the payment amount in both systems.',
        );
      }

      // Compare status
      final firestoreStatus = firestorePayment['status'] as String? ?? '';
      final stripeStatus = stripePayment['status'] as String? ?? '';

      // Map Stripe status to Firestore status
      final statusMap = {
        'succeeded': 'paid',
        'processing': 'pending',
        'requires_payment_method': 'pending',
        'requires_confirmation': 'pending',
        'requires_action': 'pending',
        'canceled': 'cancelled',
        'requires_capture': 'pending',
      };

      final expectedFirestoreStatus = statusMap[stripeStatus] ?? 'pending';

      if (firestoreStatus != expectedFirestoreStatus && stripeStatus == 'succeeded') {
        return PaymentReconciliationResult(
          isReconciled: false,
          discrepancy: 'Status mismatch: Firestore=$firestoreStatus, Stripe=$stripeStatus (expected Firestore=$expectedFirestoreStatus)',
          firestorePayment: firestorePayment,
          stripePayment: stripePayment,
          recommendation: 'Payment succeeded in Stripe but status in Firestore is incorrect. Update Firestore status to "paid".',
        );
      }

      // All checks passed
      return PaymentReconciliationResult(
        isReconciled: true,
        firestorePayment: firestorePayment,
        stripePayment: stripePayment,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error reconciling payment: $e');
      }
      return PaymentReconciliationResult(
        isReconciled: false,
        discrepancy: 'Error during reconciliation: $e',
        recommendation: 'Check logs for details',
      );
    }
  }

  /// Reconcile all payments for a facility within a date range
  static Future<Map<String, PaymentReconciliationResult>> reconcileFacilityPayments({
    required String facilityId,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 100,
  }) async {
    try {
      Query<Map<String, dynamic>> query = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('payments')
          .where('isActive', isEqualTo: true)
          .where('method', isEqualTo: 'stripe');

      if (startDate != null) {
        query = query.where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(startDate));
      }

      if (endDate != null) {
        query = query.where('createdAt', isLessThanOrEqualTo: Timestamp.fromDate(endDate));
      }

      query = query.orderBy('createdAt', descending: true).limit(limit);

      final paymentsSnapshot = await query.get();

      final results = <String, PaymentReconciliationResult>{};

      for (final doc in paymentsSnapshot.docs) {
        final paymentData = doc.data();
        final paymentIntentId = paymentData['externalPaymentId'] as String?;

        if (paymentIntentId != null && paymentIntentId.isNotEmpty) {
          final result = await reconcilePayment(
            facilityId: facilityId,
            paymentIntentId: paymentIntentId,
          );
          results[paymentIntentId] = result;
        }
      }

      return results;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error reconciling facility payments: $e');
      }
      return {};
    }
  }

  /// Get reconciliation summary statistics
  static Future<Map<String, dynamic>> getReconciliationSummary({
    required String facilityId,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final results = await reconcileFacilityPayments(
        facilityId: facilityId,
        startDate: startDate,
        endDate: endDate,
        limit: 1000,
      );

      int reconciledCount = 0;
      int discrepancyCount = 0;
      final discrepancies = <String>[];

      results.forEach((paymentIntentId, result) {
        if (result.isReconciled) {
          reconciledCount++;
        } else {
          discrepancyCount++;
          if (result.discrepancy != null) {
            discrepancies.add('$paymentIntentId: ${result.discrepancy}');
          }
        }
      });

      return {
        'total': results.length,
        'reconciled': reconciledCount,
        'discrepancies': discrepancyCount,
        'discrepancyDetails': discrepancies,
      };
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting reconciliation summary: $e');
      }
      return {
        'total': 0,
        'reconciled': 0,
        'discrepancies': 0,
        'error': e.toString(),
      };
    }
  }
}
