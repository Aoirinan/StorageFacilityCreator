import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/providers/unit_provider.dart';
import 'package:sfcapp/screens/tenant_edit_screen.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/widgets/tenant_contact_edit_dialog.dart';
import 'package:sfcapp/widgets/tenant_facility_unit_picker.dart';

/// Stands in for the save: asks the screen's question about unit 101, as
/// TenantService.updateTenant does when the unit number changes while the
/// tenant still holds 101, and returns the notice it would.
class _FakeOperations extends TenantOperationsNotifier {
  String? savedUnitNumber;
  String? savedUnitId;
  bool? freeAnswer;
  bool asked = false;

  @override
  Future<String?> updateTenant({
    required String facilityId,
    required String tenantId,
    String? name,
    String? email,
    String? phone,
    String? unitNumber,
    String? unitId,
    double? monthlyRate,
    String? notes,
    bool? isActive,
    String? governmentIdType,
    String? governmentIdNumber,
    String? governmentIdState,
    String? governmentIdCountry,
    DateTime? governmentIdIssuedAt,
    DateTime? governmentIdExpiresAt,
    bool clearGovernmentIdIssuedAt = false,
    bool clearGovernmentIdExpiresAt = false,
    List<TenantContact>? emergencyContacts,
    List<TenantVehicle>? vehicles,
    bool? portalEnabled,
    String? portalAccessCode,
    bool clearPortalAccessCode = false,
    String? portalWelcomeMessage,
    DateTime? portalLastAccessAt,
    bool resetPortalStats = false,
    DateTime? smsOptInDate,
    ConfirmFreeUnit? confirmFreeOldUnit,
  }) async {
    savedUnitNumber = unitNumber;
    savedUnitId = unitId;
    // No callback: TenantService keeps unit 101 without asking.
    if (confirmFreeOldUnit != null) {
      asked = true;
      freeAnswer = await confirmFreeOldUnit('101');
    }
    return freeAnswer == false
        ? r'Monthly rent is now $220.00 for units 101 and 102.'
        : null;
  }
}

/// Edit Tenant's unit picker used to add the picked unit silently: the old
/// unit stayed occupied by the same tenant, and the screen said "updated
/// successfully". It now asks, and shows the new rent.
void main() {
  final tenant = TenantModel(
    id: 't1',
    facilityId: 'f1',
    name: 'Ada Park',
    email: 'ada@example.com',
    phone: '5550100',
    unitNumber: '101',
    monthlyRate: 100,
    isActive: true,
    createdAt: DateTime(2026, 1, 1),
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<_FakeOperations> openAndSave(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ops = _FakeOperations();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        tenantOperationsProvider.overrideWith((ref) => ops),
        facilityProvider('f1').overrideWith((ref) async => null as FacilityModel?),
        facilityUnitsProvider('f1').overrideWith((ref) => Stream.value(const <UnitModel>[])),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => Scaffold(body: TenantEditScreen(tenant: tenant)),
              )),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Unit Number *'), '102');
    final save = find.widgetWithText(ElevatedButton, 'Save Changes');
    await tester.ensureVisible(save);
    await tester.tap(save);
    // Not pumpAndSettle: the save button spins while the question is open.
    await settle(tester);
    return ops;
  }

  testWidgets('picking another unit asks "Also free unit 101?"; Keep both shows the new rent',
      (tester) async {
    final ops = await openAndSave(tester);
    expect(ops.asked, isTrue);
    expect(find.text('Also free unit 101?'), findsOneWidget);
    expect(find.textContaining('Ada Park is getting unit 102 and still holds unit 101'),
        findsOneWidget);
    await tester.tap(find.text('Keep both'));
    await settle(tester);
    expect(ops.freeAnswer, isFalse);
    expect(ops.savedUnitNumber, '102');
    expect(find.text(r'Ada Park updated. Monthly rent is now $220.00 for units 101 and 102.'),
        findsOneWidget);
  });

  testWidgets('Free unit 101 answers yes', (tester) async {
    final ops = await openAndSave(tester);
    await tester.tap(find.text('Free unit 101'));
    await settle(tester);
    expect(ops.freeAnswer, isTrue);
    expect(find.text('Ada Park updated successfully!'), findsOneWidget);
  });

  testWidgets("the tenant page's Contact Information edit asks too, and shows the new rent",
      (tester) async {
    // The same save from the tenant page's pencil: without the question
    // the old unit stayed assigned, unasked.
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ops = _FakeOperations();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        tenantOperationsProvider.overrideWith((ref) => ops),
        facilityProvider('f1').overrideWith((ref) async => null as FacilityModel?),
        facilityUnitsProvider('f1').overrideWith((ref) => Stream.value(const <UnitModel>[])),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => editTenantContactInfo(context, ref, tenant),
              child: const Text('edit'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('edit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Unit Number *'), '102');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settle(tester);
    expect(ops.asked, isTrue);
    expect(find.text('Also free unit 101?'), findsOneWidget);
    await tester.tap(find.text('Keep both'));
    await settle(tester);
    expect(ops.savedUnitNumber, '102');
    expect(find.text(r'Contact info updated. Monthly rent is now $220.00 for units 101 and 102.'),
        findsOneWidget);
  });

  group('the unit picked from the list is saved by id', () {
    // Two units numbered 12. The picker wrote only the number, so the save
    // linked whichever unit numbered 12 came first.
    UnitModel twelve(String id, String area) => UnitModel(
          id: id,
          facilityId: 'f1',
          unitNumber: '12',
          unitType: 'standard',
          status: UnitStatus.available,
          monthlyRate: 50,
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
          createdBy: 'owner',
          area: area,
        );

    Future<_FakeOperations> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final ops = _FakeOperations();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          tenantOperationsProvider.overrideWith((ref) => ops),
          facilityProvider('f1').overrideWith((ref) async => null as FacilityModel?),
          facilityUnitsProvider('f1').overrideWith((ref) => Stream.value(
              [twelve('c2-12', 'Complex 2'), twelve('c3-12', 'Complex 3')])),
        ],
        child: MaterialApp(home: Scaffold(body: TenantEditScreen(tenant: tenant))),
      ));
      await tester.pumpAndSettle();
      final picker = find.descendant(
          of: find.byType(TenantFacilityUnitPicker),
          matching: find.byType(DropdownButtonFormField<String>));
      await tester.ensureVisible(picker);
      await tester.tap(picker);
      await tester.pumpAndSettle();
      // The areas tell the two apart.
      await tester.tap(find.text(r'Unit 12 (Complex 3) - $50.00/mo').last);
      await tester.pumpAndSettle();
      return ops;
    }

    Future<void> save(WidgetTester tester) async {
      final button = find.widgetWithText(ElevatedButton, 'Save Changes');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await settle(tester);
      await tester.tap(find.text('Keep both'));
      await settle(tester);
    }

    testWidgets('picked: the id goes with the number', (tester) async {
      final ops = await open(tester);
      await save(tester);
      expect(ops.savedUnitNumber, '12');
      expect(ops.savedUnitId, 'c3-12');
    });

    testWidgets('typed over after picking: by number again', (tester) async {
      final ops = await open(tester);
      await tester.enterText(find.widgetWithText(TextFormField, 'Unit Number *'), '14');
      await save(tester);
      expect(ops.savedUnitNumber, '14');
      expect(ops.savedUnitId, isNull);
    });
  });
}
