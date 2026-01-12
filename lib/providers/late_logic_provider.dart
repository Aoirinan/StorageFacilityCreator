import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:state_notifier/state_notifier.dart';
import '../services/late_logic_service.dart';
import '../models/payment_model.dart';
import '../models/tenant_model.dart';
import '../models/contract_model.dart';

// Provider for late statistics
final lateStatisticsProvider = FutureProvider.family<Map<String, int>, String>((ref, facilityId) async {
  return await LateLogicService.getLateStatistics(facilityId);
});

// Provider for overdue payments
final overduePaymentsProvider = FutureProvider.family<List<PaymentModel>, String>((ref, facilityId) async {
  return await LateLogicService.getOverduePayments(facilityId);
});

// Provider for tenants with overdue payments
final tenantsWithOverdueProvider = FutureProvider.family<List<TenantOverdueInfo>, String>((ref, facilityId) async {
  return await LateLogicService.getTenantsWithOverduePayments(facilityId);
});

// Provider for late fee calculation
final lateFeeProvider = FutureProvider.family<double, Map<String, String>>((ref, params) async {
  return await LateLogicService.calculateTotalLateFees(params['facilityId']!, params['tenantId']!);
});

// Provider for tenant late status
final tenantLateStatusProvider = FutureProvider.family<LateStatus, Map<String, String>>((ref, params) async {
  return await LateLogicService.getTenantLateStatus(params['facilityId']!, params['tenantId']!);
});

// Provider for payment late status
final paymentLateStatusProvider = Provider.family<LateStatus, PaymentModel>((ref, payment) {
  return LateLogicService.getPaymentLateStatus(payment);
});

// Provider for payment badge info
final paymentBadgeProvider = Provider.family<BadgeInfo, PaymentModel>((ref, payment) {
  return LateLogicService.getPaymentBadge(payment);
});

// Provider for tenant badge info
final tenantBadgeProvider = Provider.family<BadgeInfo, LateStatus>((ref, status) {
  return LateLogicService.getTenantBadge(status);
});

// Provider for contract badge info
final contractBadgeProvider = Provider.family<BadgeInfo, ContractModel>((ref, contract) {
  return LateLogicService.getContractBadge(contract);
});

// Provider for late logic operations
final lateLogicOperationsProvider = StateNotifierProvider<LateLogicOperationsNotifier, AsyncValue<void>>((ref) {
  return LateLogicOperationsNotifier();
});

class LateLogicOperationsNotifier extends StateNotifier<AsyncValue<void>> {
  LateLogicOperationsNotifier() : super(const AsyncValue.data(null));

  Future<void> applyLateFees(String facilityId) async {
    state = const AsyncValue.loading();
    try {
      await LateLogicService.applyLateFees(facilityId);
      state = const AsyncValue.data(null);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }

  Future<void> refreshLateData(String facilityId) async {
    state = const AsyncValue.loading();
    try {
      // This will trigger a refresh of all late-related providers
      // The actual refresh is handled by the individual providers
      state = const AsyncValue.data(null);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }
}

// Provider for late dashboard data
final lateDashboardProvider = FutureProvider.family<LateDashboardData, String>((ref, facilityId) async {
  final statistics = await ref.watch(lateStatisticsProvider(facilityId).future);
  final overduePayments = await ref.watch(overduePaymentsProvider(facilityId).future);
  final tenantsWithOverdue = await ref.watch(tenantsWithOverdueProvider(facilityId).future);

  return LateDashboardData(
    statistics: statistics,
    overduePayments: overduePayments,
    tenantsWithOverdue: tenantsWithOverdue,
  );
});

class LateDashboardData {
  final Map<String, int> statistics;
  final List<PaymentModel> overduePayments;
  final List<TenantOverdueInfo> tenantsWithOverdue;

  LateDashboardData({
    required this.statistics,
    required this.overduePayments,
    required this.tenantsWithOverdue,
  });

  int get totalOverdueAmount {
    return overduePayments.fold(0, (sum, payment) => sum + payment.amount.round());
  }

  double get averageDaysOverdue {
    if (overduePayments.isEmpty) return 0.0;
    final totalDays = overduePayments.fold(0, (sum, payment) => sum + payment.daysOverdue);
    return totalDays / overduePayments.length;
  }

  int get severelyOverdueCount {
    return overduePayments.where((p) => p.daysOverdue > 30).length;
  }
}

// Provider for late alerts
final lateAlertsProvider = FutureProvider.family<List<LateAlert>, String>((ref, facilityId) async {
  final overduePayments = await ref.watch(overduePaymentsProvider(facilityId).future);
  final tenantsWithOverdue = await ref.watch(tenantsWithOverdueProvider(facilityId).future);

  final alerts = <LateAlert>[];

  // Add payment alerts
  for (final payment in overduePayments) {
    final status = LateLogicService.getPaymentLateStatus(payment);
    if (status != LateStatus.current) {
      alerts.add(LateAlert(
        id: 'payment_${payment.id}',
        type: LateAlertType.payment,
        title: 'Overdue Payment',
        message: 'Payment of \$${payment.amount.toStringAsFixed(2)} is ${LateLogicService.formatDaysOverdue(payment.daysOverdue)}',
        severity: _getAlertSeverity(status),
        relatedId: payment.id,
        createdAt: DateTime.now(),
      ));
    }
  }

  // Add tenant alerts
  for (final tenantInfo in tenantsWithOverdue) {
    if (tenantInfo.status != LateStatus.current) {
      alerts.add(LateAlert(
        id: 'tenant_${tenantInfo.tenant.id}',
        type: LateAlertType.tenant,
        title: 'Tenant Overdue',
        message: '${tenantInfo.tenant.name} owes \$${tenantInfo.totalBalance.toStringAsFixed(2)} across ${tenantInfo.overduePayments} payments',
        severity: _getAlertSeverity(tenantInfo.status),
        relatedId: tenantInfo.tenant.id,
        createdAt: DateTime.now(),
      ));
    }
  }

  // Sort by severity and date
  alerts.sort((a, b) {
    final severityComparison = b.severity.index.compareTo(a.severity.index);
    if (severityComparison != 0) return severityComparison;
    return b.createdAt.compareTo(a.createdAt);
  });

  return alerts;
});

enum LateAlertType {
  payment,
  tenant,
  contract,
}

enum LateAlertSeverity {
  low,
  medium,
  high,
  critical,
}

class LateAlert {
  final String id;
  final LateAlertType type;
  final String title;
  final String message;
  final LateAlertSeverity severity;
  final String relatedId;
  final DateTime createdAt;

  LateAlert({
    required this.id,
    required this.type,
    required this.title,
    required this.message,
    required this.severity,
    required this.relatedId,
    required this.createdAt,
  });
}

LateAlertSeverity _getAlertSeverity(LateStatus status) {
  switch (status) {
    case LateStatus.current:
      return LateAlertSeverity.low;
    case LateStatus.late:
      return LateAlertSeverity.medium;
    case LateStatus.overdue:
      return LateAlertSeverity.high;
    case LateStatus.severelyOverdue:
      return LateAlertSeverity.critical;
  }
}
