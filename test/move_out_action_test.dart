import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/contract_model.dart';
import 'package:sfcapp/models/provider_params.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/providers/contract_provider.dart';
import 'package:sfcapp/providers/permission_provider.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/screens/unit_detail_screen.dart';
import 'package:sfcapp/services/move_out_service.dart';
import 'package:sfcapp/widgets/move_out_action.dart';

final _day = DateTime(2026, 9, 1);

ContractModel _contract(
  String id, {
  bool isActive = true,
  ContractStatus status = ContractStatus.signed,
  MoveOutStatus? moveOutStatus,
}) =>
    ContractModel(
      id: id,
      facilityId: 'f1',
      facilityOwnerUid: 'owner',
      tenantId: 't1',
      title: 'Rental Agreement $id',
      description: '',
      type: ContractType.storage,
      status: status,
      createdAt: _day,
      createdBy: 'owner',
      isActive: isActive,
      moveOutStatus: moveOutStatus,
    );

UnitModel _unit(String id, String number, {String? tenantId, UnitStatus? status}) => UnitModel(
      id: id,
      facilityId: 'f1',
      unitNumber: number,
      unitType: 'standard',
      status: status ?? (tenantId == null ? UnitStatus.available : UnitStatus.occupied),
      tenantId: tenantId,
      tenantName: tenantId == null ? null : 'Ada Park',
      monthlyRate: 100,
      createdAt: _day,
      updatedAt: _day,
      createdBy: 'owner',
    );

/// Where Move out went: the move-out screen's query, as the route read it.
Map<String, String>? _opened;

GoRouter _router(Widget home) => GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (context, state) => home),
        GoRoute(
          path: AppRoute.moveOut,
          builder: (context, state) {
            _opened = state.uri.queryParameters;
            return const Scaffold(body: Text('Move-out screen'));
          },
        ),
      ],
    );

class _FakeUnitActions extends UnitDetailActions {
  _FakeUnitActions(this.unitDoc, this.tenantContracts);

  final UnitModel unitDoc;
  final List<ContractModel> tenantContracts;

  @override
  Future<UnitModel?> unit(String facilityId, String unitId) async => unitDoc;

  @override
  Future<TenantModel?> tenant(String facilityId, String tenantId) async => null;

  @override
  Future<double> balance(String facilityId, String tenantId) async => 0;

  @override
  Future<List<ContractModel>> contracts(String facilityId, String tenantId) async =>
      tenantContracts;
}

/// Nothing in the app linked to the move-out screen, so an owner could not
/// run a move-out at all. Move out now sits on the tenant's page and the
/// unit's menu, for those allowed to run one, and opens the screen for the
/// right contract, facility and unit.
void main() {
  setUp(() => _opened = null);

  group('contractsOpenForMoveOut', () {
    test('keeps active contracts not yet moved out or cancelled', () {
      final open = contractsOpenForMoveOut([
        _contract('a'),
        _contract('draft', status: ContractStatus.draft),
        _contract('expired', status: ContractStatus.expired),
        _contract('ended', isActive: false),
        _contract('done', moveOutStatus: MoveOutStatus.completed),
        _contract('cancelled', status: ContractStatus.cancelled),
        _contract('started', moveOutStatus: MoveOutStatus.initiated),
      ]);
      expect(open.map((c) => c.id), ['a', 'draft', 'expired', 'started']);
    });
  });

  test('moveOutFor carries the contract, facility and optional unit', () {
    expect(
      Uri.parse(AppRoute.moveOutFor(contractId: 'c 1', facilityId: 'f1')).queryParameters,
      {'contractId': 'c 1', 'facilityId': 'f1'},
    );
    expect(
      Uri.parse(AppRoute.moveOutFor(contractId: 'c1', facilityId: 'f1', unitId: 'u7'))
          .queryParameters,
      {'contractId': 'c1', 'facilityId': 'f1', 'unitId': 'u7'},
    );
  });

  group("the tenant's page", () {
    const params = FacilityTenantParams(facilityId: 'f1', tenantId: 't1');

    Future<void> pumpButton(
      WidgetTester tester, {
      required bool allowed,
      required List<ContractModel> contracts,
      VoidCallback? onMovedOut,
    }) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          canProcessMoveOutAtFacilityProvider('f1').overrideWith((ref) async => allowed),
          tenantContractsProvider(params).overrideWith((ref) async => contracts),
        ],
        child: MaterialApp.router(
          routerConfig: _router(Scaffold(
            body: TenantMoveOutButton(
              facilityId: 'f1',
              tenantId: 't1',
              onMovedOut: onMovedOut,
            ),
          )),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('Move out opens the move-out screen for the active contract',
        (tester) async {
      await pumpButton(tester, allowed: true, contracts: [
        _contract('old', moveOutStatus: MoveOutStatus.completed),
        _contract('LZA7GPfzz84N7ri68uXl'),
      ]);
      expect(find.text('Move out'), findsOneWidget);

      await tester.tap(find.text('Move out'));
      await tester.pumpAndSettle();

      expect(find.text('Move-out screen'), findsOneWidget);
      expect(_opened, {'contractId': 'LZA7GPfzz84N7ri68uXl', 'facilityId': 'f1'});
    });

    testWidgets('with two open contracts, the owner chooses which', (tester) async {
      await pumpButton(tester, allowed: true, contracts: [_contract('c1'), _contract('c2')]);

      await tester.tap(find.text('Move out'));
      await tester.pumpAndSettle();
      expect(find.text('Move out from which contract?'), findsOneWidget);

      await tester.tap(find.text('Rental Agreement c2'));
      await tester.pumpAndSettle();
      expect(_opened, {'contractId': 'c2', 'facilityId': 'f1'});
    });

    testWidgets('a finished move-out tells the page to re-read the tenant', (tester) async {
      var movedOut = 0;
      await pumpButton(
        tester,
        allowed: true,
        contracts: [_contract('c1')],
        onMovedOut: () => movedOut++,
      );
      await tester.tap(find.text('Move out'));
      await tester.pumpAndSettle();

      // The move-out screen leaves with true once it has moved the tenant out.
      GoRouter.of(tester.element(find.text('Move-out screen'))).pop(true);
      await tester.pumpAndSettle();
      expect(movedOut, 1);
    });

    testWidgets('hidden without the processMoveOut permission', (tester) async {
      await pumpButton(tester, allowed: false, contracts: [_contract('c1')]);
      expect(find.text('Move out'), findsNothing);
    });

    testWidgets('hidden when no contract is open for a move-out', (tester) async {
      await pumpButton(tester, allowed: true, contracts: [
        _contract('done', moveOutStatus: MoveOutStatus.completed),
        _contract('cancelled', status: ContractStatus.cancelled),
      ]);
      expect(find.text('Move out'), findsNothing);
    });
  });

  group("the unit's menu", () {
    Future<void> openMenu(
      WidgetTester tester,
      UnitModel unit, {
      required bool allowed,
      List<ContractModel> contracts = const [],
    }) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          unitDetailActionsProvider.overrideWithValue(_FakeUnitActions(unit, contracts)),
          canProcessMoveOutAtFacilityProvider('f1').overrideWith((ref) async => allowed),
        ],
        child: MaterialApp.router(
          routerConfig: _router(UnitDetailScreen.fromUnit(unit)),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
    }

    testWidgets('Move out on an occupied unit opens the move-out screen for that unit',
        (tester) async {
      await openMenu(tester, _unit('u7', 'TEST-1', tenantId: 't1'),
          allowed: true, contracts: [_contract('c1')]);
      expect(find.text('Move out'), findsOneWidget);

      await tester.tap(find.text('Move out'));
      await tester.pumpAndSettle();

      expect(find.text('Move-out screen'), findsOneWidget);
      expect(_opened, {'contractId': 'c1', 'facilityId': 'f1', 'unitId': 'u7'});
    });

    testWidgets('not offered without the permission, or on a vacant unit', (tester) async {
      await openMenu(tester, _unit('u7', 'TEST-1', tenantId: 't1'), allowed: false);
      expect(find.text('Move out'), findsNothing);
      expect(find.text('Unassign Tenant'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      await openMenu(tester, _unit('u8', '8'), allowed: true);
      expect(find.text('Move out'), findsNothing);
    });

    testWidgets('a tenant with no open contract is sent to Unassign Tenant', (tester) async {
      await openMenu(tester, _unit('u7', 'TEST-1', tenantId: 't1'),
          allowed: true,
          contracts: [_contract('done', moveOutStatus: MoveOutStatus.completed)]);
      await tester.tap(find.text('Move out'));
      await tester.pumpAndSettle();

      expect(_opened, isNull);
      expect(find.textContaining('no active contract to move out from'), findsOneWidget);
      expect(find.textContaining('use Unassign Tenant'), findsOneWidget);
    });
  });

  group('unitToVacate', () {
    TenantModel tenant(String unitNumber) => TenantModel(
          id: 't1',
          facilityId: 'f1',
          name: 'Ada Park',
          email: '',
          phone: '',
          unitNumber: unitNumber,
          monthlyRate: 100,
          createdAt: _day,
        );

    test("the one unit the tenant holds, whatever their record's number says", () {
      final units = [_unit('u1', '1', tenantId: 'other'), _unit('u7', '7', tenantId: 't1')];
      expect(unitToVacate(units: units, tenant: tenant('stale'))?.id, 'u7');
    });

    test('never falls back to some other unit', () {
      // The screen took the facility's first unit when the number matched
      // none: here another tenant's.
      final units = [_unit('u1', '1', tenantId: 'other'), _unit('u2', '2')];
      expect(unitToVacate(units: units, tenant: tenant('9')), isNull);
      // Nor another tenant's unit with the same number.
      expect(unitToVacate(units: units, tenant: tenant('1')), isNull);
    });

    test('among several held, the one the record names, else the owner chooses', () {
      final units = [_unit('u1', '1', tenantId: 't1'), _unit('u2', '2', tenantId: 't1')];
      expect(unitToVacate(units: units, tenant: tenant('2'))?.id, 'u2');
      expect(unitToVacate(units: units, tenant: tenant('1, 2')), isNull);
    });

    test('an older record with no unit linked by id is found by number', () {
      final units = [_unit('u1', '1', tenantId: 'other'), _unit('u5', '5')];
      expect(unitToVacate(units: units, tenant: tenant('5'))?.id, 'u5');
    });
  });
}
