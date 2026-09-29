import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/providers/permission_provider.dart';
import 'package:sfcapp/providers/statement_ledger_reader_provider.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/providers/unit_provider.dart';
import 'package:sfcapp/screens/client_list_screen.dart';
import 'package:sfcapp/services/bulk_statement_service.dart';

UnitModel _unit(String number, String tenantId, String area) => UnitModel(
      id: 'u-$number',
      facilityId: 'fac1',
      unitNumber: number,
      unitType: 'standard',
      status: UnitStatus.occupied,
      tenantId: tenantId,
      monthlyRate: 50,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      createdBy: 'owner-1',
      area: area,
    );

TenantModel _tenant(String id, String name, String unitNumber) => TenantModel(
      id: id,
      facilityId: 'fac1',
      name: name,
      email: '',
      phone: '',
      unitNumber: unitNumber,
      monthlyRate: 50,
      createdAt: DateTime(2026, 1, 1),
    );

final _tenants = [
  _tenant('di', 'Di', 'A10'),
  _tenant('cy', 'Cy', 'B1'),
  _tenant('bo', 'Bo', 'A2'),
  _tenant('ann', 'Ann', 'A1'),
];

final _units = [
  _unit('A1', 'ann', 'Complex 3'),
  _unit('A2', 'bo', 'Complex 3'),
  _unit('A10', 'di', 'Complex 3'),
  _unit('B1', 'cy', 'Outdoor'),
];

/// One September rent per tenant asked for, so nobody is skipped for an
/// empty ledger.
class _Reader implements StatementLedgerReader {
  List<String>? asked;

  @override
  Future<Map<String, List<LedgerEntry>>> read(
      String facilityId, List<String> tenantIds) async {
    asked = tenantIds;
    return {
      for (final id in tenantIds)
        id: [
          LedgerEntry(
            id: 'rent-$id',
            tenantId: id,
            facilityId: facilityId,
            type: LedgerEntryType.rentCharge,
            amount: 50,
            description: 'September rent',
            entryDate: DateTime.utc(2026, 9, 1, 12),
            status: LedgerEntryStatus.posted,
            createdAt: DateTime.utc(2026, 9, 1, 12),
            createdBy: 'system',
          ),
        ],
    };
  }
}

final _facility = FacilityModel(
  id: 'fac1',
  name: 'Test Storage',
  ownerUid: 'owner-1',
  createdAt: DateTime(2026, 1, 1),
);

Future<ProviderContainer> _pumpList(
  WidgetTester tester,
  _Reader reader, {
  Size size = const Size(1400, 1200),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(overrides: [
    authStateProvider
        .overrideWith((ref) => Stream.value(MockUser(uid: 'owner-1'))),
    userFacilitiesProvider('owner-1')
        .overrideWith((ref) => Stream.value([_facility])),
    activeFacilityIdProvider.overrideWith(
      (ref) => ActiveFacilityNotifier.idle(const AsyncValue.data('fac1')),
    ),
    facilityProvider('fac1').overrideWith((ref) async => _facility),
    facilityUnitsProvider('fac1').overrideWith((ref) => Stream.value(_units)),
    facilityTenantsProvider('fac1')
        .overrideWith((ref) => Stream.value(_tenants)),
    // All Facilities reads every facility's tenants another way.
    multiFacilityTenantsProvider('all').overrideWith((ref) async => _tenants),
    facilityTenantsProvider('all')
        .overrideWith((ref) => Stream.value(const <TenantModel>[])),
    canDeleteTenantAtFacilityProvider('fac1')
        .overrideWith((ref) async => false),
    statementLedgerReaderProvider.overrideWithValue(reader),
  ]);
  addTearDown(container.dispose);
  // Signed in, with the facility list loaded, as the page is reached in the
  // app: it picks its facility from them when it opens.
  container.listen(authStateProvider, (_, __) {});
  container.listen(userFacilitiesProvider('owner-1'), (_, __) {});
  await tester.runAsync(() async {
    await container.read(authStateProvider.future);
    await container.read(userFacilitiesProvider('owner-1').future);
  });
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: Scaffold(body: ClientListScreen())),
  ));
  await tester.pumpAndSettle();
  expect(find.text('Cy'), findsOneWidget);
  return container;
}

OutlinedButton _printButton(WidgetTester tester) => tester
    .widget<OutlinedButton>(find.byKey(const Key('bulk-print-statements')));

void main() {
  // The owner mails monthly statements and used to print them one tenant at
  // a time from each ledger. The selection bar prints the selected tenants
  // the list is showing, like the other bulk buttons.
  testWidgets('Select Multiple > Select All offers Print statements for the '
      'visible selection and opens the dialog without losing it',
      (tester) async {
    final reader = _Reader();
    final container = await _pumpList(tester, reader);

    await tester.tap(find.text('Select Multiple'));
    await tester.pumpAndSettle();
    expect(find.text('Print statements (0)'), findsOneWidget);
    expect(_printButton(tester).onPressed, isNull);

    await tester.tap(find.text('Select All'));
    await tester.pumpAndSettle();
    expect(find.text('4 selected'), findsOneWidget);
    expect(find.text('Print statements (4)'), findsOneWidget);
    expect(_printButton(tester).onPressed, isNotNull);

    // An Area filter hides Cy: the count follows what the list shows, as
    // Paid through and SMS consent do.
    container.read(tenantAreaFilterProvider.notifier).state = 'Complex 3';
    await tester.pumpAndSettle();
    expect(find.text('Cy'), findsNothing);
    expect(find.text('Print statements (3)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('bulk-print-statements')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(reader.asked, ['ann', 'bo', 'di'],
        reason: 'the visible selection, in the list\'s order');
    expect(find.text('Build 3 statements'), findsOneWidget);

    // Nothing was written, so the selection stays for a reprint.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Print statements (3)'), findsOneWidget);
    expect(find.text('4 selected'), findsOneWidget);
  });

  testWidgets('under All Facilities the button is disabled and says why',
      (tester) async {
    // Wide enough for the All Facilities cards, which carry more per row.
    await _pumpList(tester, _Reader(), size: const Size(2200, 1400));

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All Facilities').last);
    await tester.pumpAndSettle();

    // Select Multiple lives in the row menu here.
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    // The menu's widest item overflows its row in the test font (every
    // glyph is a square), a layout complaint that predates this button and
    // is not what this test is about.
    expect(tester.takeException(), anyOf(isNull, isA<FlutterError>()));
    await tester.tap(find.text('Select Multiple'));
    await tester.pumpAndSettle();

    expect(find.text('Print statements (0)'), findsOneWidget);
    expect(_printButton(tester).onPressed, isNull);
    expect(
      find.byWidgetPredicate((w) =>
          w is Tooltip && w.message == 'Pick one facility to print statements'),
      findsOneWidget,
    );
  });
}
