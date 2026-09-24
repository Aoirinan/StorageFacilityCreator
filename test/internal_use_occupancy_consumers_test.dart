import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/pricing_rule_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/screens/yield_management_screen.dart';
import 'package:sfcapp/services/dynamic_pricing_service.dart';
import 'package:sfcapp/services/reports_service.dart';

/// The occupancy report, dynamic pricing and the yield screen's per-type
/// rows count units by FacilityStatsService.countsTowardOccupancy, the one
/// definition the dashboard and the stats function use. They counted
/// internal-use space (offices, residences) as rentable units.

UnitModel _unit(
  String id,
  UnitStatus status, {
  bool internalUse = false,
  String unitType = 'standard',
  double monthlyRate = 100,
}) =>
    UnitModel(
      id: id,
      facilityId: 'fac1',
      unitNumber: id,
      unitType: unitType,
      status: status,
      monthlyRate: monthlyRate,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      createdBy: 'owner-1',
      internalUse: internalUse,
    );

PricingRule _rule(
  String name,
  PricingRuleType type, {
  Map<String, dynamic>? conditions,
}) =>
    PricingRule(
      id: name,
      facilityId: 'fac1',
      name: name,
      type: type,
      adjustmentMethod: PricingAdjustmentMethod.fixedAmount,
      adjustmentValue: 10,
      conditions: conditions,
      createdAt: DateTime(2026, 1, 1),
      createdBy: 'owner-1',
    );

void main() {
  // Three rentable units, two of them occupied, and a vacant office.
  final units = [
    _unit('A1', UnitStatus.occupied),
    _unit('A2', UnitStatus.occupied),
    _unit('A3', UnitStatus.available),
    _unit('OFF', UnitStatus.available, internalUse: true, monthlyRate: 0),
  ];

  test('the occupancy report leaves internal-use space out', () {
    final metrics = ReportsService.occupancyMetricsFor(units);

    // Before: 4 units at 50%, against the dashboard's 3 at 67%.
    expect(metrics.totalUnits, 3);
    expect(metrics.occupiedUnits, 2);
    expect(metrics.availableUnits, 1);
    expect(metrics.occupancyRate, closeTo(66.67, 0.01));
    // Three rentable units at the average occupied rate, not four.
    expect(metrics.potentialMonthlyRevenue, 300);
  });

  test('pricing rules see the dashboard occupancy rate', () {
    final recommendations = DynamicPricingService.recommendationsFor(
      allUnits: units,
      rules: [
        _rule('Busy', PricingRuleType.occupancyBased,
            conditions: {'minOccupancy': 60}),
      ],
    );

    // Before: 2 of 4 is 50%, under the rule's 60%, so nothing was offered.
    expect([for (final r in recommendations) r.unitId], ['A3']);
  });

  test('pricing offers no price for an office', () {
    final recommendations = DynamicPricingService.recommendationsFor(
      allUnits: units,
      rules: [_rule('Demand', PricingRuleType.demandBased)],
    );

    // Before: the vacant office was offered a $10 rate.
    expect([for (final r in recommendations) r.unitId], ['A3']);
  });

  test('the yield per-type rows leave internal-use space out', () {
    final analysis = analyzeYieldUnits([
      ...units,
      _unit('B1', UnitStatus.occupied, unitType: 'climate'),
      _unit('B-RES', UnitStatus.occupied,
          unitType: 'climate', internalUse: true, monthlyRate: 0),
    ]);
    final byType = analysis['byType'] as Map<String, dynamic>;
    final standard = byType['standard'] as Map<String, dynamic>;
    final climate = byType['climate'] as Map<String, dynamic>;

    // Before: standard read 2 of 4 (50%, flagged for a price cut) and the
    // manager's residence halved climate's average rate.
    expect(standard['total'], 3);
    expect(standard['occupied'], 2);
    expect(standard['occupancyRate'], closeTo(2 / 3, 0.0001));
    expect(standard['avgRate'], 100);
    expect(climate['total'], 1);
    expect(climate['avgRate'], 100);
    expect(analysis['totalUnits'], 4);
  });

  test('a type that is all internal use has no row', () {
    final analysis = analyzeYieldUnits([
      _unit('A1', UnitStatus.occupied),
      _unit('OFF', UnitStatus.available,
          unitType: 'office', internalUse: true),
    ]);

    expect((analysis['byType'] as Map).keys, ['standard']);
  });
}
