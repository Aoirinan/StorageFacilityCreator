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

/// Stands in for the save: asks the screen's question about unit 101, as
/// TenantService.updateTenant does when the unit number changes while the
/// tenant still holds 101, and returns the notice it would.
class _FakeOperations extends TenantOperationsNotifier {
  String? savedUnitNumber;
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
}
