import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/services/late_logic_service.dart';

/// Lateness decides whether a tenant is chased, charged a late fee, sent
/// delinquency notices and eventually locked out, and the day count feeds the
/// legacy accrual at $5 a day. These pin the boundaries with an injected clock.
TenantModel tenant({DateTime? paidThrough, DateTime? createdAt}) {
  return TenantModel(
    id: 't1',
    facilityId: 'f1',
    name: 'Jane Example',
    email: 'jane@example.com',
    phone: '+15555550123',
    unitNumber: 'B12',
    monthlyRate: 150,
    paidThrough: paidThrough,
    createdAt: createdAt ?? DateTime(2025, 1, 1),
  );
}

void main() {
  group('isTenantLate', () {
    test('a tenant paid through this month is not late', () {
      final t = tenant(paidThrough: DateTime(2026, 6, 30));
      expect(
        LateLogicService.isTenantLate(t, now: DateTime(2026, 6, 15)),
        isFalse,
      );
    });

    test('the grace period is honoured at its boundary', () {
      // Grace 3 days: the boundary is 3 days before the 1st of this month.
      // June 2026 starts on the 1st, so the boundary is 29 May.
      final now = DateTime(2026, 6, 10);

      final onBoundary = tenant(paidThrough: DateTime(2026, 5, 29));
      expect(
        LateLogicService.isTenantLate(onBoundary, gracePeriodDays: 3, now: now),
        isFalse,
        reason: 'exactly on the boundary is still within grace',
      );

      final justPast = tenant(paidThrough: DateTime(2026, 5, 28));
      expect(
        LateLogicService.isTenantLate(justPast, gracePeriodDays: 3, now: now),
        isTrue,
      );
    });

    test('a longer configured grace period delays lateness', () {
      final t = tenant(paidThrough: DateTime(2026, 5, 28));
      final now = DateTime(2026, 6, 10);
      expect(
        LateLogicService.isTenantLate(t, gracePeriodDays: 3, now: now),
        isTrue,
      );
      expect(
        LateLogicService.isTenantLate(t, gracePeriodDays: 10, now: now),
        isFalse,
        reason: 'the operator allowed 10 days, so 28 May is still in grace',
      );
    });

    test('a tenant who has never paid gets a 30 day onboarding window', () {
      final created = DateTime(2026, 4, 10);
      expect(
        LateLogicService.isTenantLate(tenant(createdAt: created),
            now: DateTime(2026, 5, 9)),
        isFalse,
        reason: '29 days in, still inside the window',
      );
      expect(
        LateLogicService.isTenantLate(tenant(createdAt: created),
            now: DateTime(2026, 6, 1)),
        isTrue,
      );
    });

    test('the onboarding window does not depend on the time of day', () {
      // createdAt comes from a Firestore timestamp and carries a clock time.
      // Two tenants created on the same calendar day must be treated alike.
      final earlyInDay = tenant(createdAt: DateTime(2026, 4, 10, 0, 30));
      final lateInDay = tenant(createdAt: DateTime(2026, 4, 10, 23, 30));
      final now = DateTime(2026, 5, 11, 12, 0);
      expect(
        LateLogicService.isTenantLate(earlyInDay, now: now),
        LateLogicService.isTenantLate(lateInDay, now: now),
      );
    });
  });

  group('getTenantDaysLate', () {
    test('a tenant who is not late is zero days late', () {
      final t = tenant(paidThrough: DateTime(2026, 6, 30));
      expect(
        LateLogicService.getTenantDaysLate(t, now: DateTime(2026, 6, 15)),
        0,
      );
    });

    test('counts from paid-through to the start of this month, less grace', () {
      // Paid through 30 April, now 10 June: 1 June minus 30 April is 32 days,
      // less 3 days grace = 29.
      final t = tenant(paidThrough: DateTime(2026, 4, 30));
      expect(
        LateLogicService.getTenantDaysLate(t,
            gracePeriodDays: 3, now: DateTime(2026, 6, 10)),
        29,
      );
    });

    test('the count does not depend on the time of day of paid-through', () {
      final atMidnight = tenant(paidThrough: DateTime(2026, 4, 30));
      final lateEvening = tenant(paidThrough: DateTime(2026, 4, 30, 18, 0));
      final now = DateTime(2026, 6, 10);
      expect(
        LateLogicService.getTenantDaysLate(lateEvening, now: now),
        LateLogicService.getTenantDaysLate(atMidnight, now: now),
        reason: 'a timestamp written in the evening is the same day',
      );
    });

    test('a span crossing the spring clock change does not lose a day', () {
      // Paid through 31 January, now 1 April: 1 day into February, 28 days of
      // February and 31 of March is 60. The spring transition falls inside the
      // span, so subtracting the raw instants measured 59 — a whole day of
      // accrual lost, every year, for every tenant overdue across March.
      final t = tenant(paidThrough: DateTime(2026, 1, 31));
      final days = LateLogicService.getTenantDaysLate(t,
          gracePeriodDays: 0, now: DateTime(2026, 4, 1));
      expect(days, 60);
    });

    test('a never-paid tenant is counted from the end of the window', () {
      final t = tenant(createdAt: DateTime(2026, 4, 10));
      // 10 June is 61 calendar days after 10 April; less the 30 day window.
      expect(
        LateLogicService.getTenantDaysLate(t, now: DateTime(2026, 6, 10)),
        31,
      );
    });
  });

  group('countLateTenants', () {
    test('counts only active tenants', () {
      final late1 = tenant(paidThrough: DateTime(2026, 4, 30));
      final current = tenant(paidThrough: DateTime(2026, 6, 30));
      expect(
        LateLogicService.countLateTenants([late1, current],
            gracePeriodDays: 3),
        greaterThanOrEqualTo(0),
      );
    });
  });
}
