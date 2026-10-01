import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/contract_model.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/transfer_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/screens/unit_detail_screen.dart';
import 'package:sfcapp/services/move_out_service.dart';
import 'package:sfcapp/services/transfer_service.dart';
import 'package:sfcapp/utils/statement_lines.dart';
import 'package:sfcapp/widgets/autopay_controls.dart';

/// The move-out's unit and rent, the ledger's refund sign on statements and
/// transfers, Assign Tenant's list and the Disable autopay button.
void main() {
  final day = DateTime(2026, 9, 1);

  UnitModel unit(String number, UnitStatus status, String? tenantId,
          {double rate = 100}) =>
      UnitModel(
        id: 'u$number',
        facilityId: 'f1',
        unitNumber: number,
        unitType: 'standard',
        status: status,
        tenantId: tenantId,
        monthlyRate: rate,
        createdAt: day,
        updatedAt: day,
        createdBy: 'owner',
      );

  group('move-out: which unit it frees', () {
    // The screen took the unit numbered as the tenant's unitNumber, or else
    // the facility's first unit; app contracts record no unit. Moving a
    // two-unit tenant out through the second unit's contract freed the
    // primary unit.
    final units = [
      unit('7', UnitStatus.occupied, 't2'),
      unit('101', UnitStatus.occupied, 't1'),
      unit('102', UnitStatus.lockout, 't1', rate: 150),
      unit('103', UnitStatus.available, null),
    ];

    test('the owner picks from the units the tenant holds, their unit number first', () {
      final picked = MoveOutService.moveOutUnitChoices(
          tenantId: 't1', tenantUnitNumber: '101', units: units);
      expect(picked.choices.map((u) => u.id), ['u101', 'u102']);
      expect(picked.initial?.id, 'u101');
    });

    test('the unit the contract was signed for is picked first', () {
      final contract = ContractModel(
        id: 'c1',
        facilityId: 'f1',
        facilityOwnerUid: 'owner',
        tenantId: 't1',
        title: 'Lease',
        description: '',
        type: ContractType.lease,
        status: ContractStatus.signed,
        createdAt: day,
        createdBy: 'publicMoveIn',
        customFields: {
          'onlineMoveInContext': {'unitId': 'u102'},
        },
      );
      expect(MoveOutService.contractUnitId(contract), 'u102');
      final picked = MoveOutService.moveOutUnitChoices(
        tenantId: 't1',
        tenantUnitNumber: '101',
        units: units,
        contractUnitId: MoveOutService.contractUnitId(contract),
      );
      expect(picked.initial?.id, 'u102');
    });

    test("never another tenant's unit, even when their unit number names none", () {
      final picked = MoveOutService.moveOutUnitChoices(
          tenantId: 't3', tenantUnitNumber: '7', units: units);
      expect(picked.choices, isEmpty);
      expect(picked.initial, isNull);
    });

    test('holding none, a unit still linked to them or free under their number, so the contract can end', () {
      final stale = [unit('9', UnitStatus.available, 't3'), ...units];
      expect(
          MoveOutService.moveOutUnitChoices(
                  tenantId: 't3', tenantUnitNumber: '', units: stale)
              .initial
              ?.id,
          'u9');
      expect(
          MoveOutService.moveOutUnitChoices(
                  tenantId: 't4', tenantUnitNumber: '103', units: units)
              .initial
              ?.id,
          'u103');
    });

    test("keeping another unit, only the vacated unit's rate is prorated", () {
      // 250 is 101 (100) and 102 (150): prorating 250 for leaving 101
      // credited 102's unused days too.
      expect(
          MoveOutService.prorationRate(
              tenantRate: 250, unitRate: 100, keepsOtherUnits: true),
          100);
      expect(
          MoveOutService.prorationRate(
              tenantRate: 90, unitRate: 100, keepsOtherUnits: false),
          90,
          reason: 'their only unit: what they are billed');
    });
  });

  group("the ledger's refund sign, everywhere a balance is carried", () {
    LedgerEntry entry(LedgerEntryType type, double amount) => LedgerEntry(
          id: '${type.name}$amount',
          tenantId: 't1',
          facilityId: 'f1',
          type: type,
          amount: amount,
          entryDate: day,
          status: LedgerEntryStatus.posted,
          createdAt: day,
          createdBy: 'owner',
        );

    test("a statement's balance is the ledger's: a refund raises it", () {
      // $100 rent paid, $50 back as a move-out credit, refunded in cash.
      // The ledger (a plain sum) says 0; the statement counted the refund as
      // a payment and showed a $100 credit.
      final rows = [
        entry(LedgerEntryType.rentCharge, 100),
        entry(LedgerEntryType.payment, -100),
        entry(LedgerEntryType.credit, -50),
        entry(LedgerEntryType.refund, 50),
      ];
      final statement = buildStatementLines(rows).closingBalance;
      final ledger = rows.fold<double>(0, (b, e) => b + e.amount);
      expect(statement, 0);
      expect(statement, ledger);
    });

    test('a transfer credits the old unit (negative) and charges the new: the net the screen showed', () {
      // The credit was posted positive, so the ledger (what autopay
      // collects) charged both.
      final transfer = TransferModel(
        id: 'x1',
        facilityId: 'f1',
        tenantId: 't1',
        fromUnitId: 'u101',
        toUnitId: 'u103',
        fromUnitNumber: '101',
        toUnitNumber: '103',
        status: TransferStatus.pending,
        transferDate: day,
        fromUnitProratedRent: 66.67,
        toUnitProratedRent: 80,
        fromUnitRate: 100,
        toUnitRate: 120,
        netAmount: 13.33,
        ledgerEntryIds: const [],
        createdAt: day,
        createdBy: 'owner',
      );
      final rows = TransferService.transferLedgerRows(transfer);
      expect(rows.map((r) => (r.type, r.amount)), [
        (LedgerEntryType.credit, -66.67),
        (LedgerEntryType.rentCharge, 80.0),
      ]);
      final posted = rows.fold<double>(0, (b, r) => b + r.amount);
      expect((posted * 100).round(), (transfer.netAmount * 100).round());
    });
  });

  group("a transfer's rent", () {
    test("their only unit: the new unit's rate, as before", () {
      final rent = TransferService.rentAfterTransfer(
        tenantName: 'Ada Park',
        current: 100,
        kept: const [],
        from: (unitNumber: '101', rate: 100),
        to: (unitNumber: '103', rate: 120),
      );
      expect(rent.monthlyRate, 120);
      expect(rent.notice, isNull);
    });

    test('holding another unit: only the transferred unit changes', () {
      // It was set to the new unit's rate alone, dropping unit 102's 150.
      final rent = TransferService.rentAfterTransfer(
        tenantName: 'Ada Park',
        current: 250,
        kept: const [(unitNumber: '102', rate: 150)],
        from: (unitNumber: '101', rate: 100),
        to: (unitNumber: '103', rate: 120),
      );
      expect(rent.monthlyRate, 270);
      expect(rent.notice, r'Monthly rent is now $270.00 for units 102 and 103.');

      final unsure = TransferService.rentAfterTransfer(
        tenantName: 'Ada Park',
        current: 200,
        kept: const [(unitNumber: '102', rate: 150)],
        from: (unitNumber: '101', rate: 100),
        to: (unitNumber: '103', rate: 120),
      );
      expect(unsure.monthlyRate, isNull);
      expect(unsure.notice, startsWith("Check Ada Park's rent"));
    });
  });

  test('Assign Tenant lists inactive tenants too, after the active ones', () {
    // A tenant whose only unit was just unassigned is inactive; the list
    // had active tenants only, so moving them (Unassign, then Assign) was
    // impossible from here.
    TenantModel tenant(String id, String name, bool active) => TenantModel(
          id: id,
          facilityId: 'f1',
          name: name,
          email: '',
          phone: '',
          unitNumber: '',
          monthlyRate: 0,
          createdAt: day,
          isActive: active,
        );
    final listed = tenantsForAssignPicker([
      tenant('t1', 'Zed Moved', false),
      tenant('t2', 'Bo Diaz', true),
      tenant('t3', 'Ada Park', true),
      tenant('t4', 'Cy Old', false),
    ]);
    expect(listed.map((t) => t.name), ['Ada Park', 'Bo Diaz', 'Cy Old', 'Zed Moved']);
  });

  group('Disable autopay is there whenever autopay is set up', () {
    Future<List<bool>> pump(WidgetTester tester,
        {required bool displayOn, Map<String, dynamic>? billing}) async {
      final set = <bool>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AutopayControls(
            displayOn: displayOn,
            billing: billing,
            busy: false,
            onSet: set.add,
          ),
        ),
      ));
      return set;
    }

    testWidgets('a legacy subscription, with the card showing OFF: Disable, which cancels it', (tester) async {
      // The facility delete sends owners to Disable autopay, which showed
      // only for the ON state, never for this tenant.
      final set = await pump(tester,
          displayOn: false, billing: {'stripeSubscriptionId': 'sub_legacy'});
      expect(find.text('Enable autopay'), findsNothing);
      await tester.tap(find.text('Disable autopay'));
      expect(set, [false]);
    });

    testWidgets('armed from the billing panel only: Disable', (tester) async {
      await pump(tester, displayOn: false, billing: {'autopayEnabled': true});
      expect(find.text('Disable autopay'), findsOneWidget);
    });

    testWidgets('nothing set up: Enable', (tester) async {
      final set = await pump(tester, displayOn: false, billing: {'autopayEnabled': false});
      expect(find.text('Disable autopay'), findsNothing);
      await tester.tap(find.text('Enable autopay'));
      expect(set, [true]);
    });
  });
}
