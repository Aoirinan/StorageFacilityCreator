import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/services/late_logic_service.dart';

TenantModel _tenant(
  String id, {
  double rate = 100,
  DateTime? paidThrough,
  bool isActive = true,
}) {
  return TenantModel(
    id: id,
    facilityId: 'fac1',
    name: id,
    email: '',
    phone: '',
    unitNumber: id,
    monthlyRate: rate,
    paidThrough: paidThrough,
    createdAt: DateTime(2025, 1, 1),
    isActive: isActive,
  );
}

PaymentModel _overduePayment(String tenantId, {double amount = 100}) {
  final due = DateTime.now().subtract(const Duration(days: 40));
  return PaymentModel(
    id: 'p-$tenantId',
    tenantId: tenantId,
    facilityId: 'fac1',
    contractId: 'c1',
    amount: amount,
    status: PaymentStatus.pending,
    method: PaymentMethod.cash,
    dueDate: due,
    createdAt: due,
    updatedAt: due,
    createdBy: 'test',
  );
}

void main() {
  final now = DateTime(2026, 9, 23);
  final lateDate = DateTime(2026, 6, 30);
  final paidAhead = DateTime(2026, 9, 30);
  const flatFifteen = LateFeeRules(lateFeeType: 'flat', lateFeeAmount: 15);

  group('buildOverdueList', () {
    test('fees on payment records come from the rules passed in', () {
      // The rules are now taken once from facility.billingSettings instead of
      // a facility-doc read per tenant; they must still be the ones applied.
      final list = LateLogicService.buildOverdueList(
        paymentsByTenant: {
          'a': [_overduePayment('a')],
        },
        paymentTenants: {'a': _tenant('a')},
        paidThroughCandidates: const [],
        feeRules: flatFifteen,
        graceDays: 3,
        now: now,
      );
      expect(list, hasLength(1));
      expect(list.single.totalLateFees, 15);
      expect(list.single.totalDue, 100);
    });

    test('lists each tenant once, skips inactive, current and unknown tenants', () {
      final list = LateLogicService.buildOverdueList(
        paymentsByTenant: {
          'a': [_overduePayment('a')],
          'no-doc': [_overduePayment('no-doc')],
        },
        paymentTenants: {'a': _tenant('a', paidThrough: lateDate)},
        paidThroughCandidates: [
          _tenant('a', paidThrough: lateDate), // already listed via payments
          _tenant('late', rate: 300, paidThrough: lateDate),
          _tenant('archived', paidThrough: lateDate, isActive: false),
          _tenant('current', paidThrough: paidAhead),
        ],
        feeRules: flatFifteen,
        graceDays: 3,
        now: now,
      );
      expect(list.map((o) => o.tenant.id), ['late', 'a']);
      final late = list.first;
      expect(late.totalDue, 300);
      expect(late.maxDaysOverdue, greaterThan(0));
    });
  });

  group('gracePeriodDaysFromBillingSettings', () {
    test('parses exactly as getFacilityGracePeriodDays always has', () {
      expect(LateLogicService.gracePeriodDaysFromBillingSettings({'gracePeriodDays': 7}), 7);
      expect(LateLogicService.gracePeriodDaysFromBillingSettings({'gracePeriodDays': '5'}), 5);
      expect(LateLogicService.gracePeriodDaysFromBillingSettings({'gracePeriodDays': 'x'}), 3);
      expect(LateLogicService.gracePeriodDaysFromBillingSettings(const {}), 3);
      expect(LateLogicService.gracePeriodDaysFromBillingSettings(null), 3);
    });
  });
}
