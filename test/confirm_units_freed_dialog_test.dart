import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/unit_model.dart';
// Both screens that delete tenants ask through this dialog; imported so a
// call that stops compiling fails here, not only in the analyzer.
import 'package:sfcapp/screens/client_detail_screen.dart';
import 'package:sfcapp/screens/client_list_screen.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/widgets/confirm_units_freed_dialog.dart';

/// Permanent delete of a tenant with no history frees the units they still
/// hold; the owner is shown which before anything is deleted.
void main() {
  const freeing = [
    TenantDeletePlan(
      tenantId: 't1',
      tenantName: 'Ada Park',
      heldUnits: [HeldUnit('101', UnitStatus.occupied)],
    ),
  ];

  Future<bool?> ask(WidgetTester tester, String button) async {
    bool? answer;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => answer = await confirmUnitsFreedDialog(context, freeing),
          child: const Text('Delete'),
        ),
      ),
    ));
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Free this unit?'), findsOneWidget);
    expect(find.textContaining('• Ada Park: unit 101'), findsOneWidget);
    await tester.tap(find.text(button));
    await tester.pumpAndSettle();
    return answer;
  }

  testWidgets('names the unit; Cancel says no', (tester) async {
    expect(await ask(tester, 'Cancel'), isFalse);
  });

  testWidgets('names the unit; the delete button says yes', (tester) async {
    expect(await ask(tester, 'Delete and free unit'), isTrue);
  });

  test('both tenant screens compile against the delete API', () {
    expect(ClientDetailScreen, isNotNull);
    expect(ClientListScreen, isNotNull);
  });
}
