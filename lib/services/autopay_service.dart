import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/payment_method_model.dart';
import '../models/ledger_entry_model.dart';
import '../models/tenant_model.dart';
import 'payment_method_service.dart';
import 'ledger_service.dart';
import 'tenant_service.dart';
import 'audit_service.dart';
import 'facility_service.dart';
import 'package:cloud_functions/cloud_functions.dart';

/// Service for processing autopay payments
class AutopayService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Process autopay for a payment method
  /// This should be called by a background job (Cloud Function)
  static Future<AutopayResult> processAutopay({
    required PaymentMethod paymentMethod,
    required TenantModel tenant,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 [Autopay] Processing autopay for tenant: ${tenant.id}, method: ${paymentMethod.id}');
      }

      // Check if payment is due
      if (!_isPaymentDue(paymentMethod, tenant)) {
        if (kDebugMode) {
          print('ℹ️ [Autopay] Payment not due yet');
        }
        return AutopayResult(
          success: false,
          skipped: true,
          reason: 'Payment not due yet',
        );
      }

      // Calculate amount to charge
      final amount = await _calculateAutopayAmount(
        paymentMethod: paymentMethod,
        tenant: tenant,
      );

      if (amount <= 0) {
        if (kDebugMode) {
          print('ℹ️ [Autopay] No amount to charge');
        }
        return AutopayResult(
          success: false,
          skipped: true,
          reason: 'No amount to charge',
        );
      }

      // Process payment via Stripe (or other payment processor)
      final paymentResult = await _processStripePayment(
        paymentMethod: paymentMethod,
        tenant: tenant,
        amount: amount,
      );

      if (!paymentResult.success) {
        // Update payment method with failure
        await PaymentMethodService.updateAutopayResult(
          tenantId: tenant.id,
          facilityId: tenant.facilityId,
          methodId: paymentMethod.id,
          result: 'failed',
          error: paymentResult.error,
          nextRun: _calculateNextRun(paymentMethod.autopaySchedule),
        );

        return AutopayResult(
          success: false,
          skipped: false,
          reason: paymentResult.error ?? 'Payment processing failed',
        );
      }

      // Create ledger entry for payment
      final ledgerEntry = await LedgerService.createLedgerEntry(
        tenantId: tenant.id,
        facilityId: tenant.facilityId,
        type: LedgerEntryType.payment,
        amount: -amount, // Negative for payments
        description: 'Autopay Payment - ${paymentMethod.displayName}',
        referenceId: paymentResult.transactionId,
        entryDate: DateTime.now(),
        status: LedgerEntryStatus.posted,
        metadata: {
          'autopay': true,
          'paymentMethodId': paymentMethod.id,
          'stripePaymentIntentId': paymentResult.transactionId,
        },
      );

      // Allocate payment to charges
      await LedgerService.allocatePayment(
        paymentId: paymentResult.transactionId ?? ledgerEntry.id,
        tenantId: tenant.id,
        facilityId: tenant.facilityId,
        paymentAmount: amount,
      );

      // Update payment method with success
      await PaymentMethodService.updateAutopayResult(
        tenantId: tenant.id,
        facilityId: tenant.facilityId,
        methodId: paymentMethod.id,
        result: 'success',
        nextRun: _calculateNextRun(paymentMethod.autopaySchedule),
      );

      // Audit log
      await AuditService.logAutopayProcessed(
        facilityId: tenant.facilityId,
        tenantId: tenant.id,
        methodId: paymentMethod.id,
        amount: amount,
        transactionId: paymentResult.transactionId,
      );

      if (kDebugMode) {
        print('✅ [Autopay] Successfully processed autopay: ${paymentResult.transactionId}');
      }

      return AutopayResult(
        success: true,
        skipped: false,
        transactionId: paymentResult.transactionId,
        amount: amount,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Autopay] Error processing autopay: $e');
      }

      // Update payment method with error
      await PaymentMethodService.updateAutopayResult(
        tenantId: tenant.id,
        facilityId: tenant.facilityId,
        methodId: paymentMethod.id,
        result: 'failed',
        error: e.toString(),
        nextRun: _calculateNextRun(paymentMethod.autopaySchedule),
      );

      return AutopayResult(
        success: false,
        skipped: false,
        reason: e.toString(),
      );
    }
  }

  /// Check if payment is due based on autopay schedule
  static bool _isPaymentDue(PaymentMethod method, TenantModel tenant) {
    if (method.autopayNextRun == null) return false;

    final now = DateTime.now();
    final nextRun = method.autopayNextRun!;

    // Check if we're past the scheduled date
    return now.isAfter(nextRun) || now.isAtSameMomentAs(nextRun);
  }

  /// Calculate amount to charge for autopay
  static Future<double> _calculateAutopayAmount({
    required PaymentMethod paymentMethod,
    required TenantModel tenant,
  }) async {
    if (paymentMethod.autopaySchedule == null) {
      // No schedule - charge full balance
      return await LedgerService.getLedgerBalance(
        tenantId: tenant.id,
        facilityId: tenant.facilityId,
      );
    }

    final schedule = paymentMethod.autopaySchedule!;

    // If fixed amount specified, use that
    if (schedule.amount != null && schedule.amount! > 0) {
      double amount = schedule.amount!;

      // Add insurance if configured
      if (schedule.includeInsurance) {
        final insuranceAmount = await _getInsuranceAmount(tenant);
        amount += insuranceAmount;
      }

      return amount;
    }

    // Otherwise, charge full balance
    final balance = await LedgerService.getLedgerBalance(
      tenantId: tenant.id,
      facilityId: tenant.facilityId,
    );

      // Add insurance if configured
      if (schedule.includeInsurance) {
        final insuranceAmount = await _getInsuranceAmount(tenant);
        balance += insuranceAmount;
      }

    return balance;
  }

  /// Get insurance amount from tenant or facility settings
  static Future<double> _getInsuranceAmount(TenantModel tenant) async {
    try {
      // Check if tenant has insurance amount in metadata or custom fields
      // For now, check facility billing settings for default insurance amount
      final facility = await FacilityService.getFacility(tenant.facilityId);
      if (facility != null && facility.billingSettings != null) {
        final defaultInsurance = facility.billingSettings!['defaultInsuranceAmount'];
        if (defaultInsurance != null) {
          return (defaultInsurance as num).toDouble();
        }
      }
      return 0.0;
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ [Autopay] Error getting insurance amount: $e');
      }
      return 0.0;
    }
  }

  /// Process payment via Stripe
  static Future<PaymentProcessingResult> _processStripePayment({
    required PaymentMethod paymentMethod,
    required TenantModel tenant,
    required double amount,
  }) async {
    try {
      if (paymentMethod.stripePaymentMethodId == null) {
        throw Exception('No Stripe payment method ID');
      }

      if (kDebugMode) {
        print('💳 [Autopay] Processing Stripe payment: $amount');
        print('   Payment Method: ${paymentMethod.stripePaymentMethodId}');
        print('   Customer: ${paymentMethod.stripeCustomerId}');
      }

      // Call Cloud Function to process payment
      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('processStripePayment');
      
      final result = await callable.call({
        'facilityId': tenant.facilityId,
        'tenantId': tenant.id,
        'paymentMethodId': paymentMethod.stripePaymentMethodId,
        'customerId': paymentMethod.stripeCustomerId,
        'amount': amount,
        'description': 'Autopay - ${tenant.name}',
      });

      final data = result.data as Map<String, dynamic>;
      
      if (data['success'] == true) {
        return PaymentProcessingResult(
          success: true,
          transactionId: data['transactionId'] as String,
        );
      } else {
        return PaymentProcessingResult(
          success: false,
          error: data['error'] as String? ?? 'Payment failed',
          requiresAction: data['requiresAction'] == true,
          clientSecret: data['clientSecret'] as String?,
        );
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Autopay] Stripe payment failed: $e');
      }
      return PaymentProcessingResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  /// Calculate next run date based on schedule
  static DateTime _calculateNextRun(AutopaySchedule? schedule) {
    if (schedule == null) {
      // Default to next month
      final now = DateTime.now();
      return DateTime(now.year, now.month + 1, 1);
    }

    final now = DateTime.now();

    switch (schedule.frequency) {
      case AutopayFrequency.monthly:
        final day = schedule.dayOfMonth ?? 1;
        var nextMonth = DateTime(now.year, now.month + 1, day);
        // Handle months with fewer days
        if (day > 28 && nextMonth.day != day) {
          nextMonth = DateTime(now.year, now.month + 1, 0); // Last day of month
        }
        return nextMonth;

      case AutopayFrequency.weekly:
        final dayOfWeek = schedule.dayOfWeek ?? 1;
        var daysUntilNext = (dayOfWeek - now.weekday) % 7;
        if (daysUntilNext == 0) daysUntilNext = 7;
        return now.add(Duration(days: daysUntilNext));

      case AutopayFrequency.quarterly:
        final day = schedule.dayOfMonth ?? 1;
        var nextQuarter = DateTime(now.year, now.month + 3, day);
        if (day > 28 && nextQuarter.day != day) {
          nextQuarter = DateTime(now.year, now.month + 3, 0);
        }
        return nextQuarter;

      case AutopayFrequency.annually:
        final day = schedule.dayOfMonth ?? 1;
        var nextYear = DateTime(now.year + 1, now.month, day);
        if (day > 28 && nextYear.day != day) {
          nextYear = DateTime(now.year + 1, now.month, 0);
        }
        return nextYear;
    }
  }
}

class AutopayResult {
  final bool success;
  final bool skipped;
  final String? reason;
  final String? transactionId;
  final double? amount;

  AutopayResult({
    required this.success,
    required this.skipped,
    this.reason,
    this.transactionId,
    this.amount,
  });
}

class PaymentProcessingResult {
  final bool success;
  final String? transactionId;
  final String? error;

  PaymentProcessingResult({
    required this.success,
    this.transactionId,
    this.error,
  });
}

