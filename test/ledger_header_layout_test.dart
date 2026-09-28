import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/providers/ledger_provider.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/screens/ledger_screen.dart';
import 'package:sfcapp/widgets/tenant_prev_next.dart';

TenantModel _t(String id, String name, String unit) => TenantModel(
      id: id,
      facilityId: 'f1',
      name: name,
      email: '$id@example.com',
      phone: '',
      unitNumber: unit,
      monthlyRate: 50,
      createdAt: DateTime(2026, 1, 1),
    );

final _tenant = _t('b', 'Patricia Renter-Longfellow', 'C2-10');
final _facility = [
  _t('a', 'Al', 'C2-2'),
  _tenant,
  _t('c', 'Cy', 'C10-1'),
];

void main() {
  // The ledger's page area: the window less the 240px sidebar (784 in a
  // 1024 window), a phone, the narrowest one-row header (900 inside the
  // page's padding) and a wide desktop.
  for (final width in [400.0, 784.0, 932.0, 1200.0]) {
    testWidgets('ledger header at ${width.toInt()}px: nothing overflows and '
        'the name shows', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          ledgerStreamProvider(
            LedgerParams(tenantId: _tenant.id, facilityId: _tenant.facilityId),
          ).overrideWith((ref) => Stream.value(const <LedgerEntry>[])),
          facilityTenantsProvider('f1')
              .overrideWith((ref) => Stream.value(_facility)),
        ],
        child: MaterialApp(
          home: Scaffold(body: LedgerScreen(tenant: _tenant)),
        ),
      ));
      await tester.pumpAndSettle();

      // A RenderFlex overflow is reported as an exception.
      expect(tester.takeException(), isNull);

      final name = find.text(_tenant.name);
      expect(name, findsOneWidget);
      expect(tester.getSize(name).width, greaterThan(100));
      expect(find.text('Unit C2-10'), findsOneWidget);

      // Previous / next and where this tenant is.
      expect(find.text('2 of 3'), findsOneWidget);
      expect(find.byTooltip(previousTenantTooltip), findsOneWidget);
      expect(find.byTooltip(nextTenantTooltip), findsOneWidget);

      // Every button whole on screen.
      for (final label in ['Generate Invoice', 'Add entry']) {
        final rect = tester.getRect(find.text(label));
        expect(rect.left, greaterThanOrEqualTo(0), reason: label);
        expect(rect.right, lessThanOrEqualTo(width), reason: label);
      }
      for (final tooltip in ['Back to tenant', 'Filter', 'Statement']) {
        final rect = tester.getRect(find.byTooltip(tooltip));
        expect(rect.right, lessThanOrEqualTo(width), reason: tooltip);
      }
    });
  }
}
