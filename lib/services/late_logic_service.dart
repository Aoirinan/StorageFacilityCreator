import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/payment_model.dart';
import '../models/tenant_model.dart';
import '../models/contract_model.dart';
import 'tenant_service.dart';
import 'facility_service.dart';

/// The operator's configured late fee rules, as the settings screen writes them.
///
/// Mirrors the `rules` argument of `resolveLateFee` in
/// `functions-automation/src/delinquencyAutomation.ts`, which is what actually
/// charges the tenant. Anything the app displays has to be derived the same way
/// or the operator reads one number on screen and the tenant is billed another.
class LateFeeRules {
  final int gracePeriodDays;
  final double baseLateFee;
  final double dailyLateFee;
  final String? lateFeeType;
  final double? lateFeeAmount;
  final double? maxLateFee;

  const LateFeeRules({
    this.gracePeriodDays = LateLogicService.defaultGracePeriodDays,
    this.baseLateFee = LateLogicService.defaultBaseLateFee,
    this.dailyLateFee = LateLogicService.defaultDailyLateFee,
    this.lateFeeType,
    this.lateFeeAmount,
    this.maxLateFee,
  });

  /// Read the rules out of `facility.billingSettings`.
  ///
  /// Values arrive from Firestore as int, double or String depending on how
  /// they were written, so each is coerced rather than cast.
  factory LateFeeRules.fromBillingSettings(Map<String, dynamic>? settings) {
    if (settings == null) return const LateFeeRules();

    int asInt(Object? v, int fallback) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v == null) return fallback;
      return int.tryParse(v.toString()) ?? fallback;
    }

    double asDouble(Object? v, double fallback) {
      if (v is num) return v.toDouble();
      if (v == null) return fallback;
      return double.tryParse(v.toString()) ?? fallback;
    }

    double? asNullableDouble(Object? v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    final type = settings['lateFeeType']?.toString();

    return LateFeeRules(
      gracePeriodDays: asInt(
          settings['gracePeriodDays'], LateLogicService.defaultGracePeriodDays),
      baseLateFee:
          asDouble(settings['baseLateFee'], LateLogicService.defaultBaseLateFee),
      dailyLateFee: asDouble(
          settings['dailyLateFee'], LateLogicService.defaultDailyLateFee),
      lateFeeType: (type == null || type.isEmpty) ? null : type,
      lateFeeAmount: asNullableDouble(settings['lateFeeAmount']),
      maxLateFee: asNullableDouble(settings['maxLateFee']),
    );
  }
}

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

  // Defaults when facility has no billing settings
  static const double defaultBaseLateFee = 25.00;
  static const double defaultDailyLateFee = 5.00;
  static const int defaultGracePeriodDays = 3;
  static const int _defaultGracePeriodDays = defaultGracePeriodDays;
  static const int _severeOverdueDays = 30;

  /// The late fee for one overdue tenant, in dollars.
  ///
  /// A Dart port of `resolveLateFee` in
  /// `functions-automation/src/delinquencyAutomation.ts`. The scheduled job
  /// there is what posts the charge; this exists so the app can show the same
  /// number. Keep the two in step — `functions-automation/src/test/lateFee.test.ts`
  /// and `test/late_fee_rules_test.dart` cover the same cases on each side.
  ///
  /// Prefers what the operator configured (`lateFeeType` flat or percentage
  /// with `lateFeeAmount`). The legacy daily accrual applies only when nothing
  /// is configured, and is bounded: uncapped it reached $310 on a $150 unit
  /// after two months. The cap is `maxLateFee` where set, otherwise the
  /// outstanding balance, because a late fee above the debt it is charged on is
  /// not defensible.
  static double resolveLateFee({
    required LateFeeRules rules,
    required int daysLate,
    required double balance,
  }) {
    double fee;
    final configured = rules.lateFeeAmount;
    if (configured != null && configured > 0) {
      fee = rules.lateFeeType == 'percentage'
          ? (balance * configured) / 100
          : configured;
    } else {
      fee = rules.baseLateFee +
          (daysLate - rules.gracePeriodDays) * rules.dailyLateFee;
    }

    // A non-positive cap clamps to zero rather than disabling the cap. Guarding
    // the comparison with `cap > 0` meant a tenant who owed nothing fell through
    // uncapped: 90 days late on a $0 balance resolved to $460.
    final maxFee = rules.maxLateFee;
    final cap = (maxFee != null && maxFee > 0) ? maxFee : balance;
    if (fee > cap) fee = cap;
    if (fee < 0) fee = 0;
    return double.parse(fee.toStringAsFixed(2));
  }

  /// Grace period for a facility (from Billing Settings). Use this so "late" matches what the owner configured.
  static Future<int> getFacilityGracePeriodDays(String facilityId) async {
    final facility = await FacilityService.getFacility(facilityId);
    final grace = facility?.billingSettings?['gracePeriodDays'];
    if (grace is int) return grace;
    if (grace != null) return int.tryParse(grace.toString()) ?? _defaultGracePeriodDays;
    return _defaultGracePeriodDays;
  }

  /// Whole calendar days from [from] to [to], ignoring the time of day.
  ///
  /// Both endpoints are rebuilt as UTC midnights. Subtracting the raw instants
  /// made the answer depend on two things it should not: what time of day a
  /// record happened to be written (Firestore timestamps carry one), and
  /// whether the span crossed a daylight-saving change, which makes a local
  /// day 23 or 25 hours long and truncates a day away. Either shifts the
  /// legacy accrual by a day, which is $5.
  static int _calendarDaysBetween(DateTime from, DateTime to) {
    final a = DateTime.utc(from.year, from.month, from.day);
    final b = DateTime.utc(to.year, to.month, to.day);
    return b.difference(a).inDays;
  }

  /// Whether a tenant is late, using the facility's grace period (or default 3 days).
  ///
  /// [now] is injectable so the boundaries can be tested; it defaults to the
  /// current time.
  static bool isTenantLate(TenantModel tenant,
      {int? gracePeriodDays, DateTime? now}) {
    final grace = gracePeriodDays ?? _defaultGracePeriodDays;
    final today = now ?? DateTime.now();
    final startOfCurrentMonth = DateTime(today.year, today.month, 1);
    final paidThroughDate = tenant.paidThrough;

    if (paidThroughDate == null) {
      final daysSinceCreation = _calendarDaysBetween(tenant.createdAt, today);
      if (daysSinceCreation <= 30) return false;
      final tenantCreatedThisMonth = tenant.createdAt.year == today.year &&
          tenant.createdAt.month == today.month;
      if (tenantCreatedThisMonth) return false;
      return true;
    }
    final graceBoundary = startOfCurrentMonth.subtract(Duration(days: grace));
    return paidThroughDate.isBefore(graceBoundary);
  }

  /// Days late (0 if not late). Use facility grace period when available.
  static int getTenantDaysLate(TenantModel tenant,
      {int? gracePeriodDays, DateTime? now}) {
    final grace = gracePeriodDays ?? _defaultGracePeriodDays;
    final today = now ?? DateTime.now();
    if (!isTenantLate(tenant, gracePeriodDays: grace, now: today)) return 0;
    final startOfCurrentMonth = DateTime(today.year, today.month, 1);
    final paidThroughDate = tenant.paidThrough;

    // Never paid: align with [isTenantLate] — late after the 30-day onboarding window.
    if (paidThroughDate == null) {
      final daysSinceCreation = _calendarDaysBetween(tenant.createdAt, today);
      return daysSinceCreation > 30 ? daysSinceCreation - 30 : 1;
    }

    final difference =
        _calendarDaysBetween(paidThroughDate, startOfCurrentMonth) - grace;
    return difference < 0 ? 0 : difference;
  }

  /// Count active tenants whose paid-through date puts them past the grace period.
  static int countLateTenants(
    Iterable<TenantModel> tenants, {
    int? gracePeriodDays,
  }) {
    var count = 0;
    for (final tenant in tenants) {
      if (tenant.isActive == true &&
          isTenantLate(tenant, gracePeriodDays: gracePeriodDays)) {
        count++;
      }
    }
    return count;
  }

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
      // Return empty list instead of rethrowing so delinquency can still show tenant-based past due
      return [];
    }
  }

  static Future<List<TenantOverdueInfo>> getTenantsWithOverduePayments(String facilityId) async {
    try {
      if (kDebugMode) {
        print('🔄 Getting tenants with overdue payments for facility: $facilityId');
      }

      // Get overdue payments (may return [] if query fails or no payments exist)
      List<PaymentModel> overduePayments;
      try {
        overduePayments = await getOverduePayments(facilityId);
      } catch (_) {
        overduePayments = [];
      }

      final paymentsByTenant = <String, List<PaymentModel>>{};
      for (final payment in overduePayments) {
        paymentsByTenant.putIfAbsent(payment.tenantId, () => []).add(payment);
      }

      final results = <TenantOverdueInfo>[];
      final trackedTenantIds = <String>{};

      // Add tenants who have overdue payment records
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

        final feeRules = await getFacilityLateFeeRules(facilityId);
        final graceDaysForFees = feeRules.gracePeriodDays;
        final totalDue = tenantPayments.fold<double>(0, (sum, payment) => sum + payment.amount);
        final totalLateFees = tenantPayments.fold<double>(0, (sum, payment) => sum + calculateLateFee(payment, rules: feeRules));
        final maxDaysOverdue = tenantPayments.fold<int>(0, (max, payment) => payment.daysOverdue > max ? payment.daysOverdue : max);
        final status = _statusForOverduePayments(tenantPayments, gracePeriodDays: graceDaysForFees);

        results.add(TenantOverdueInfo(
          tenant: tenant,
          payments: tenantPayments,
          totalDue: totalDue,
          totalLateFees: totalLateFees,
          overduePayments: tenantPayments.length,
          maxDaysOverdue: maxDaysOverdue,
          status: status,
        ));
        trackedTenantIds.add(tenant.id);
      }

      // Use facility's grace period so "late" matches what the owner set in Billing Settings
      final graceDays = await getFacilityGracePeriodDays(facilityId);
      final now = DateTime.now();
      final startOfCurrentMonth = DateTime(now.year, now.month, 1);
      final graceCutoff = startOfCurrentMonth.subtract(Duration(days: graceDays));

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
        if (!tenant.isActive) continue;
        if (!isTenantLate(tenant, gracePeriodDays: graceDays)) continue;

        final daysLate = getTenantDaysLate(tenant, gracePeriodDays: graceDays);
        final status = _statusForDaysLate(daysLate);
        results.add(
          TenantOverdueInfo(
            tenant: tenant,
            payments: const [],
            totalDue: tenant.monthlyRate,
            totalLateFees: 0,
            overduePayments: 0,
            maxDaysOverdue: daysLate,
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

  /// The late fee shown for one overdue payment.
  ///
  /// Pass [rules] wherever the facility is in scope. Without them this falls
  /// back to the platform defaults, which is what every call site used to do
  /// unconditionally: a facility that had configured a flat $15 fee saw the
  /// uncapped $25 + $5/day accrual on screen while the tenant was charged $15.
  static double calculateLateFee(
    PaymentModel payment, {
    int? gracePeriodDays,
    LateFeeRules? rules,
  }) {
    if (payment.status != PaymentStatus.pending) return 0.0;
    if (!payment.isOverdue) return 0.0;

    final effective = rules ??
        LateFeeRules(
            gracePeriodDays: gracePeriodDays ?? defaultGracePeriodDays);
    final daysOverdue = payment.daysOverdue;
    if (daysOverdue <= effective.gracePeriodDays) return 0.0;

    return resolveLateFee(
      rules: effective,
      daysLate: daysOverdue,
      balance: payment.amount,
    );
  }

  /// The facility's configured late fee rules (from Billing Settings).
  static Future<LateFeeRules> getFacilityLateFeeRules(String facilityId) async {
    final facility = await FacilityService.getFacility(facilityId);
    return LateFeeRules.fromBillingSettings(facility?.billingSettings);
  }

  static Future<double> calculateTotalLateFees(String facilityId, String tenantId) async {
    try {
      final feeRules = await getFacilityLateFeeRules(facilityId);
      final graceDays = feeRules.gracePeriodDays;
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
        totalLateFees += calculateLateFee(payment, rules: feeRules);
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

  static LateStatus getPaymentLateStatus(PaymentModel payment, {int? gracePeriodDays}) {
    if (payment.status != PaymentStatus.pending) return LateStatus.current;
    if (!payment.isOverdue) return LateStatus.current;

    final grace = gracePeriodDays ?? _defaultGracePeriodDays;
    final daysOverdue = payment.daysOverdue;
    if (daysOverdue <= grace) return LateStatus.current;
    if (daysOverdue <= 15) return LateStatus.late;
    if (daysOverdue <= _severeOverdueDays) return LateStatus.overdue;
    return LateStatus.severelyOverdue;
  }

  static Future<LateStatus> getTenantLateStatus(String facilityId, String tenantId) async {
    try {
      final graceDays = await getFacilityGracePeriodDays(facilityId);
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
      return _statusForOverduePayments(payments, gracePeriodDays: graceDays);
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

  /// Removed. Late fees are applied by the scheduled `processDelinquencyAutomation`
  /// job, which is the single engine for them.
  ///
  /// This client-side version was a second, conflicting engine and every part of
  /// it was unsafe:
  ///
  /// * No idempotency. It created a new `payments` row on every call with no
  ///   check for an existing fee, so two clicks meant two fees. The scheduled
  ///   job looks for an existing `lateFee` ledger entry in the month first.
  /// * It compounded on itself. The fee was written `status: pending` with
  ///   `dueDate: now`, so `getOverduePayments` picked it up days later and
  ///   charged a late fee on the late fee.
  /// * Uncapped and hardcoded at $25 plus $5 a day, ignoring the facility's own
  ///   `lateFeeAmount` and `lateFeeType`. Sixty days overdue produced a $310 fee
  ///   on a $150 unit, above what lien statutes generally allow.
  /// * Wrong collection. It wrote to `payments` while the scheduled job writes
  ///   to `ledgers`, so the two engines could not see each other's work.
  ///
  /// Nothing in the app called it. [calculateLateFee] is kept for display.

  // --- Statistics ---

  /// Late statistics use tenant-based past-due (paidThrough / daysLate) so they match
  /// the dashboard and tenant list. Tenants with overdue payment records are also included
  /// via getTenantsWithOverduePayments.
  static Future<Map<String, int>> getLateStatistics(String facilityId) async {
    try {
      final graceDays = await getFacilityGracePeriodDays(facilityId);
      final tenants = await TenantService.getTenantsForFacility(facilityId);
      final activeTenants = tenants.where((t) => t.isActive == true).toList();

      int currentCount = 0;
      int lateCount = 0;
      int overdueCount = 0;
      int severelyOverdueCount = 0;

      for (final tenant in activeTenants) {
        if (!isTenantLate(tenant, gracePeriodDays: graceDays)) {
          currentCount++;
          continue;
        }
        final daysLate = getTenantDaysLate(tenant, gracePeriodDays: graceDays);
        final status = _statusForDaysLate(daysLate);
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
        'totalTenantsWithOverdue': lateCount + overdueCount + severelyOverdueCount,
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

  static LateStatus _statusForOverduePayments(List<PaymentModel> payments, {int? gracePeriodDays}) {
    if (payments.isEmpty) return LateStatus.current;

    final grace = gracePeriodDays ?? _defaultGracePeriodDays;
    int maxDaysOverdue = 0;
    for (final payment in payments) {
      if (payment.daysOverdue > maxDaysOverdue) {
        maxDaysOverdue = payment.daysOverdue;
      }
    }

    if (maxDaysOverdue <= grace) return LateStatus.current;
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
