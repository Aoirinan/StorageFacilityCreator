import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/payment_model.dart';
import '../models/tenant_model.dart';
import '../models/contract_model.dart';

enum LateStatus {
  current,
  late,
  overdue,
  severelyOverdue,
}

enum BadgeType {
  paymentStatus,
  contractStatus,
  tenantStatus,
  facilityStatus,
}

class BadgeInfo {
  final String label;
  final String color;
  final String icon;
  final String description;

  const BadgeInfo({
    required this.label,
    required this.color,
    required this.icon,
    required this.description,
  });
}

class TenantOverdueInfo {
  final TenantModel tenant;
  final List<PaymentModel> payments;
  final double totalDue;
  final double totalLateFees;
  final int overduePayments;
  final int maxDaysOverdue;
  final LateStatus status;

  TenantOverdueInfo({
    required this.tenant,
    required this.payments,
    required this.totalDue,
    required this.totalLateFees,
    required this.overduePayments,
    required this.maxDaysOverdue,
    required this.status,
  });

  double get totalBalance => totalDue + totalLateFees;
}

class LateLogicService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  // Late fee configuration
  static const double _baseLateFee = 25.00;
  static const double _dailyLateFee = 5.00;
  static const int _gracePeriodDays = 3;
  static const int _severeOverdueDays = 30;

  // --- Late Payment Detection ---

  static Future<List<PaymentModel>> getOverduePayments(String facilityId) async {
    try {
      if (kDebugMode) {
        print('🔄 Getting overdue payments for facility: $facilityId');
      }

      final now = DateTime.now();
      final querySnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('payments')
          .where('status', isEqualTo: PaymentStatus.pending.toString().split('.').last)
          .where('dueDate', isLessThan: now)
          .orderBy('dueDate', descending: true)
          .get();

      final overduePayments = querySnapshot.docs
          .map((doc) => PaymentModel.fromFirestore(doc))
          .toList();

      if (kDebugMode) {
        print('✅ Found ${overduePayments.length} overdue payments');
      }

      return overduePayments;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting overdue payments: $e');
      }
      rethrow;
    }
  }

  static Future<List<TenantOverdueInfo>> getTenantsWithOverduePayments(String facilityId) async {
    try {
      if (kDebugMode) {
        print('🔄 Getting tenants with overdue payments for facility: $facilityId');
      }

      final overduePayments = await getOverduePayments(facilityId);
      if (overduePayments.isEmpty) {
        return [];
      }

      final paymentsByTenant = <String, List<PaymentModel>>{};
      for (final payment in overduePayments) {
        paymentsByTenant.putIfAbsent(payment.tenantId, () => []).add(payment);
      }

      final results = <TenantOverdueInfo>[];

      for (final entry in paymentsByTenant.entries) {
        final tenantDoc = await _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .doc(entry.key)
            .get();

        if (!tenantDoc.exists) {
          continue;
        }

        final tenant = TenantModel.fromFirestore(tenantDoc);
        final tenantPayments = entry.value;

        final totalDue = tenantPayments.fold<double>(0, (sum, payment) => sum + payment.amount);
        final totalLateFees = tenantPayments.fold<double>(0, (sum, payment) => sum + calculateLateFee(payment));
        final maxDaysOverdue = tenantPayments.fold<int>(0, (max, payment) => payment.daysOverdue > max ? payment.daysOverdue : max);
        final status = _statusForOverduePayments(tenantPayments);

        results.add(TenantOverdueInfo(
          tenant: tenant,
          payments: tenantPayments,
          totalDue: totalDue,
          totalLateFees: totalLateFees,
          overduePayments: tenantPayments.length,
          maxDaysOverdue: maxDaysOverdue,
          status: status,
        ));
      }

      final trackedTenantIds = results.map((info) => info.tenant.id).toSet();
      final now = DateTime.now();
      final startOfCurrentMonth = DateTime(now.year, now.month, 1);
      final graceCutoff = startOfCurrentMonth.subtract(Duration(days: _gracePeriodDays));

      final lateTenantsSnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .where('paidThrough', isLessThan: Timestamp.fromDate(graceCutoff))
          .get();

      final neverPaidSnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .where('paidThrough', isNull: true)
          .get();

      final additionalDocs = [
        ...lateTenantsSnapshot.docs,
        ...neverPaidSnapshot.docs,
      ];

      for (final doc in additionalDocs) {
        if (!doc.exists) continue;
        if (trackedTenantIds.contains(doc.id)) continue;

        final tenant = TenantModel.fromFirestore(doc);
        if (!tenant.isLate) {
          continue;
        }

        final status = _statusForDaysLate(tenant.daysLate);
        results.add(
          TenantOverdueInfo(
            tenant: tenant,
            payments: const [],
            totalDue: tenant.monthlyRate,
            totalLateFees: 0,
            overduePayments: 0,
            maxDaysOverdue: tenant.daysLate,
            status: status,
          ),
        );
        trackedTenantIds.add(tenant.id);
      }

      results.sort((a, b) => b.totalBalance.compareTo(a.totalBalance));

      if (kDebugMode) {
        print('✅ Found ${results.length} tenants with overdue payments');
      }

      return results;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting tenants with overdue payments: $e');
      }
      rethrow;
    }
  }

  // --- Late Fee Calculation ---

  static double calculateLateFee(PaymentModel payment) {
    if (payment.status != PaymentStatus.pending) return 0.0;
    if (!payment.isOverdue) return 0.0;

    final daysOverdue = payment.daysOverdue;
    if (daysOverdue <= _gracePeriodDays) return 0.0;

    return _baseLateFee + ((daysOverdue - _gracePeriodDays) * _dailyLateFee);
  }

  static Future<double> calculateTotalLateFees(String facilityId, String tenantId) async {
    try {
      final querySnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('payments')
          .where('tenantId', isEqualTo: tenantId)
          .where('status', isEqualTo: PaymentStatus.pending.toString().split('.').last)
          .get();

      double totalLateFees = 0.0;
      for (final doc in querySnapshot.docs) {
        final payment = PaymentModel.fromFirestore(doc);
        totalLateFees += calculateLateFee(payment);
      }

      return totalLateFees;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error calculating total late fees: $e');
      }
      return 0.0;
    }
  }

  // --- Status Determination ---

  static LateStatus getPaymentLateStatus(PaymentModel payment) {
    if (payment.status != PaymentStatus.pending) return LateStatus.current;
    if (!payment.isOverdue) return LateStatus.current;

    final daysOverdue = payment.daysOverdue;
    if (daysOverdue <= _gracePeriodDays) return LateStatus.current;
    if (daysOverdue <= 15) return LateStatus.late;
    if (daysOverdue <= _severeOverdueDays) return LateStatus.overdue;
    return LateStatus.severelyOverdue;
  }

  static Future<LateStatus> getTenantLateStatus(String facilityId, String tenantId) async {
    try {
      final overduePayments = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('payments')
          .where('tenantId', isEqualTo: tenantId)
          .where('status', isEqualTo: PaymentStatus.pending.toString().split('.').last)
          .where('dueDate', isLessThan: Timestamp.fromDate(DateTime.now()))
          .get();

      if (overduePayments.docs.isEmpty) return LateStatus.current;

      final payments = overduePayments.docs.map(PaymentModel.fromFirestore).toList();
      return _statusForOverduePayments(payments);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting tenant late status: $e');
      }
      return LateStatus.current;
    }
  }

  // --- Badge System ---

  static BadgeInfo getPaymentBadge(PaymentModel payment) {
    final status = getPaymentLateStatus(payment);
    
    switch (status) {
      case LateStatus.current:
        return const BadgeInfo(
          label: 'Current',
          color: 'green',
          icon: 'check_circle',
          description: 'Payment is current',
        );
      case LateStatus.late:
        return const BadgeInfo(
          label: 'Late',
          color: 'orange',
          icon: 'warning',
          description: 'Payment is late',
        );
      case LateStatus.overdue:
        return const BadgeInfo(
          label: 'Overdue',
          color: 'red',
          icon: 'error',
          description: 'Payment is overdue',
        );
      case LateStatus.severelyOverdue:
        return const BadgeInfo(
          label: 'Severely Overdue',
          color: 'red',
          icon: 'dangerous',
          description: 'Payment is severely overdue',
        );
    }
  }

  static BadgeInfo getTenantBadge(LateStatus status) {
    switch (status) {
      case LateStatus.current:
        return const BadgeInfo(
          label: 'Good Standing',
          color: 'green',
          icon: 'check_circle',
          description: 'Tenant is in good standing',
        );
      case LateStatus.late:
        return const BadgeInfo(
          label: 'Late',
          color: 'orange',
          icon: 'warning',
          description: 'Tenant has late payments',
        );
      case LateStatus.overdue:
        return const BadgeInfo(
          label: 'Overdue',
          color: 'red',
          icon: 'error',
          description: 'Tenant has overdue payments',
        );
      case LateStatus.severelyOverdue:
        return const BadgeInfo(
          label: 'Severely Overdue',
          color: 'red',
          icon: 'dangerous',
          description: 'Tenant is severely overdue',
        );
    }
  }

  static BadgeInfo getContractBadge(ContractModel contract) {
    final now = DateTime.now();
    final daysUntilExpiry = contract.expiresAt?.difference(now).inDays ?? 0;

    if (daysUntilExpiry < 0) {
      return const BadgeInfo(
        label: 'Expired',
        color: 'red',
        icon: 'error',
        description: 'Contract has expired',
      );
    } else if (daysUntilExpiry <= 30) {
      return BadgeInfo(
        label: 'Expiring Soon',
        color: 'orange',
        icon: 'warning',
        description: 'Contract expires in $daysUntilExpiry days',
      );
    } else {
      return const BadgeInfo(
        label: 'Active',
        color: 'green',
        icon: 'check_circle',
        description: 'Contract is active',
      );
    }
  }

  // --- Late Fee Application ---

  static Future<void> applyLateFees(String facilityId) async {
    try {
      if (kDebugMode) {
        print('🔄 Applying late fees for facility: $facilityId');
      }

      final overduePayments = await getOverduePayments(facilityId);
      
      for (final payment in overduePayments) {
        final lateFee = calculateLateFee(payment);
        if (lateFee > 0) {
          // Create a late fee payment record
          await _firestore.collection('facilities').doc(facilityId).collection('payments').add({
            'tenantId': payment.tenantId,
            'facilityId': payment.facilityId,
            'contractId': payment.contractId,
            'amount': lateFee,
            'status': PaymentStatus.pending.toString().split('.').last,
            'method': PaymentMethod.cash.toString().split('.').last,
            'dueDate': Timestamp.fromDate(DateTime.now()),
            'notes': 'Late fee for payment due ${payment.dueDate}',
            'createdAt': Timestamp.fromDate(DateTime.now()),
            'updatedAt': Timestamp.fromDate(DateTime.now()),
            'createdBy': _auth.currentUser?.uid ?? '',
          });

          if (kDebugMode) {
            print('✅ Applied late fee of \$${lateFee.toStringAsFixed(2)} for payment ${payment.id}');
          }
        }
      }

      if (kDebugMode) {
        print('✅ Late fee application complete for facility: $facilityId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error applying late fees: $e');
      }
      rethrow;
    }
  }

  // --- Statistics ---

  static Future<Map<String, int>> getLateStatistics(String facilityId) async {
    try {
      final overduePayments = await getOverduePayments(facilityId);
      final tenantsWithOverdue = await getTenantsWithOverduePayments(facilityId);

      int currentCount = 0;
      int lateCount = 0;
      int overdueCount = 0;
      int severelyOverdueCount = 0;

      for (final payment in overduePayments) {
        final status = getPaymentLateStatus(payment);
        switch (status) {
          case LateStatus.current:
            currentCount++;
            break;
          case LateStatus.late:
            lateCount++;
            break;
          case LateStatus.overdue:
            overdueCount++;
            break;
          case LateStatus.severelyOverdue:
            severelyOverdueCount++;
            break;
        }
      }

      return {
        'current': currentCount,
        'late': lateCount,
        'overdue': overdueCount,
        'severelyOverdue': severelyOverdueCount,
        'totalTenantsWithOverdue': tenantsWithOverdue.length,
      };
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting late statistics: $e');
      }
      return {
        'current': 0,
        'late': 0,
        'overdue': 0,
        'severelyOverdue': 0,
        'totalTenantsWithOverdue': 0,
      };
    }
  }

  // --- Utility Methods ---

  static String formatLateStatus(LateStatus status) {
    switch (status) {
      case LateStatus.current:
        return 'Current';
      case LateStatus.late:
        return 'Late';
      case LateStatus.overdue:
        return 'Overdue';
      case LateStatus.severelyOverdue:
        return 'Severely Overdue';
    }
  }

  static String formatDaysOverdue(int days) {
    if (days == 0) return 'Due today';
    if (days == 1) return '1 day overdue';
    return '$days days overdue';
  }

  static LateStatus _statusForOverduePayments(List<PaymentModel> payments) {
    if (payments.isEmpty) return LateStatus.current;

    int maxDaysOverdue = 0;
    for (final payment in payments) {
      if (payment.daysOverdue > maxDaysOverdue) {
        maxDaysOverdue = payment.daysOverdue;
      }
    }

    if (maxDaysOverdue <= _gracePeriodDays) return LateStatus.current;
    if (maxDaysOverdue <= 15) return LateStatus.late;
    if (maxDaysOverdue <= _severeOverdueDays) return LateStatus.overdue;
    return LateStatus.severelyOverdue;
  }

  static LateStatus _statusForDaysLate(int daysLate) {
    if (daysLate <= 0) return LateStatus.current;
    if (daysLate <= 15) return LateStatus.late;
    if (daysLate <= _severeOverdueDays) return LateStatus.overdue;
    return LateStatus.severelyOverdue;
  }
}
