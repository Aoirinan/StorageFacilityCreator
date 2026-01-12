import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:state_notifier/state_notifier.dart';
import '../models/payment_model.dart';
import '../models/provider_params.dart';
import '../services/payment_service.dart';

// Payment list provider (real-time stream)
final paymentListProvider = StreamProvider.family<List<PaymentModel>, String>((ref, facilityId) {
  return PaymentService.getPaymentsForFacilityStream(facilityId);
});

// Payment stats provider
final paymentStatsProvider = FutureProvider.family<Map<String, dynamic>, String>((ref, facilityId) async {
  final payments = await PaymentService.getPaymentsForFacility(facilityId);
  final total = payments.length;
  final paid = payments.where((p) => p.status == PaymentStatus.paid || p.status == PaymentStatus.completed).length;
  final pending = payments.where((p) => p.status == PaymentStatus.pending).length;
  final overdue = payments.where((p) => p.isOverdue).length;
  
  return {
    'total': total,
    'paid': paid,
    'pending': pending,
    'overdue': overdue,
  };
});

// Payments for facility provider
final paymentsForFacilityProvider = FutureProvider.family<List<PaymentModel>, String>((ref, facilityId) async {
  return await PaymentService.getPaymentsForFacility(facilityId);
});

// Tenant payments provider
final tenantPaymentsProvider = FutureProvider.family<List<PaymentModel>, FacilityTenantParams>((ref, params) async {
  if (!params.isValid) return const <PaymentModel>[];
  return PaymentService.getPaymentsForTenant(params.facilityId, params.tenantId);
});

final tenantPaymentSummaryProvider =
    FutureProvider.family<Map<String, dynamic>, FacilityTenantParams>((ref, params) async {
  if (!params.isValid) {
    return const {
      'outstanding': 0.0,
      'pendingCount': 0,
      'nextDueDate': null,
      'recentPending': const <PaymentModel>[],
    };
  }
  return PaymentService.getTenantPaymentSummary(params.facilityId, params.tenantId);
});

// Late payments provider
final latePaymentsProvider = FutureProvider.family<List<PaymentModel>, String>((ref, facilityId) async {
  return await PaymentService.getLatePayments(facilityId);
});

// Payment statistics provider
final paymentStatisticsProvider = FutureProvider.family<Map<String, dynamic>, String>((ref, facilityId) async {
  return await PaymentService.getPaymentStatistics(facilityId);
});

// Payment operations provider
final paymentOperationsProvider = StateNotifierProvider<PaymentOperationsNotifier, AsyncValue<void>>((ref) {
  return PaymentOperationsNotifier();
});

class PaymentOperationsNotifier extends StateNotifier<AsyncValue<void>> {
  PaymentOperationsNotifier() : super(const AsyncValue.data(null));

  Future<void> createPayment({
    required String tenantId,
    required String facilityId,
    required String contractId,
    required double amount,
    required PaymentMethod method,
    required DateTime dueDate,
    String? notes,
    Map<String, dynamic>? metadata,
  }) async {
    state = const AsyncValue.loading();
    try {
      await PaymentService.createPayment(
        tenantId: tenantId,
        facilityId: facilityId,
        contractId: contractId,
        amount: amount,
        method: method,
        dueDate: dueDate,
        notes: notes,
        metadata: metadata,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> markPaymentAsPaid({
    required String facilityId,
    required String paymentId,
    required PaymentMethod method,
    String? transactionId,
    String? receiptUrl,
  }) async {
    state = const AsyncValue.loading();
    try {
        await PaymentService.markPaymentAsPaid(
          facilityId: facilityId,
          paymentId: paymentId,
          method: method,
          transactionId: transactionId,
        );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> archivePayment(String facilityId, String paymentId) async {
    state = const AsyncValue.loading();
    try {
      await PaymentService.archivePayment(facilityId, paymentId);
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> deletePayment(String facilityId, String paymentId) async {
    state = const AsyncValue.loading();
    try {
      await PaymentService.deletePayment(facilityId, paymentId);
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> processPayment({
    required String facilityId,
    required String paymentId,
    required PaymentMethod method,
    String? transactionId,
  }) async {
    state = const AsyncValue.loading();
    try {
      // Process payment logic here
      await PaymentService.markPaymentAsPaid(
        facilityId: facilityId,
        paymentId: paymentId,
        method: method,
        transactionId: transactionId,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> markTenantAsPaid({
    required String facilityId,
    required String tenantId,
    required double amount,
    PaymentMethod method = PaymentMethod.cash,
    String? notes,
  }) async {
    state = const AsyncValue.loading();
    try {
      await PaymentService.markTenantAsPaid(
        facilityId: facilityId,
        tenantId: tenantId,
        amount: amount,
        method: method,
        notes: notes,
      );
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> updatePayment({
    required String facilityId,
    required String paymentId,
    double? amount,
    String? description,
    DateTime? dueDate,
  }) async {
    state = const AsyncValue.loading();
    try {
      // Update payment logic here - would need to implement in service
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> generateMonthlyRentPayments({
    required String facilityId,
    required String tenantId,
    required double amount,
    required DateTime startDate,
    required int months,
  }) async {
    state = const AsyncValue.loading();
    try {
      // Generate monthly payments logic here - would need to implement in service
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }
}