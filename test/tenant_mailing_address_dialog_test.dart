import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/address_model.dart';
import 'package:sfcapp/utils/mailing_address_edit.dart';
import 'package:sfcapp/widgets/tenant_mailing_address_dialog.dart';

class _DialogResult {
  bool done = false;
  MailingAddressFields? picked;
}

/// The tenant page's Edit Mailing Address dialog on its own: what it shows
/// for the stored entry, what it refuses, and what it hands back.
void main() {
  final stored = Address(
    id: 'a1',
    type: AddressType.mailing,
    street1: 'PO Box 12',
    street2: 'Apt 4',
    city: 'Anytown',
    state: 'ND',
    zipCode: '79401',
    isPrimary: true,
    createdAt: DateTime(2026, 9, 26),
  );

  Future<_DialogResult> open(WidgetTester tester, {Address? current}) async {
    final holder = _DialogResult();
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              holder.picked = await showTenantMailingAddressDialog(context, current: current);
              holder.done = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return holder;
  }

  String fieldText(WidgetTester tester, String key) =>
      tester.widget<TextFormField>(find.byKey(Key(key))).controller!.text;

  Future<void> type(WidgetTester tester, String key, String text) =>
      tester.enterText(find.byKey(Key(key)), text);

  testWidgets('fills the fields from the stored address and offers Remove', (tester) async {
    await open(tester, current: stored);
    expect(find.text('Edit Mailing Address'), findsOneWidget);
    expect(fieldText(tester, 'mailing-address-street'), 'PO Box 12');
    expect(fieldText(tester, 'mailing-address-street2'), 'Apt 4');
    expect(fieldText(tester, 'mailing-address-city'), 'Anytown');
    expect(fieldText(tester, 'mailing-address-state'), 'ND');
    expect(fieldText(tester, 'mailing-address-zip'), '79401');
    expect(find.byKey(const Key('mailing-address-remove')), findsOneWidget);
  });

  testWidgets('no stored address: empty fields and no Remove', (tester) async {
    await open(tester);
    expect(fieldText(tester, 'mailing-address-street'), isEmpty);
    expect(find.byKey(const Key('mailing-address-remove')), findsNothing);
  });

  testWidgets('Save returns what was typed, Apt included', (tester) async {
    final result = await open(tester);
    await type(tester, 'mailing-address-street', '12 Example Ave');
    await type(tester, 'mailing-address-street2', 'Suite B');
    await type(tester, 'mailing-address-city', 'Exampleville');
    await type(tester, 'mailing-address-state', 'MT');
    await type(tester, 'mailing-address-zip', '73001');
    await tester.tap(find.byKey(const Key('mailing-address-save')));
    await tester.pumpAndSettle();

    expect(result.done, isTrue);
    final picked = result.picked!;
    expect(picked.isBlank, isFalse);
    expect(picked.street1, '12 Example Ave');
    expect(picked.street2, 'Suite B');
    expect(picked.city, 'Exampleville');
    expect(picked.state, 'MT');
    expect(picked.zipCode, '73001');
  });

  testWidgets('a street-only import cannot be saved without city, state and ZIP', (tester) async {
    final streetOnly = Address(
      id: 'imp',
      type: AddressType.mailing,
      street1: '12 Example Ave',
      city: '',
      state: '',
      zipCode: '',
      isPrimary: true,
      createdAt: DateTime(2026, 9, 26),
    );
    final result = await open(tester, current: streetOnly);
    await tester.tap(find.byKey(const Key('mailing-address-save')));
    await tester.pumpAndSettle();

    expect(result.done, isFalse, reason: 'the dialog stays open');
    expect(find.text('Required'), findsNWidgets(3), reason: 'city, state and ZIP');

    await type(tester, 'mailing-address-city', 'Exampleville');
    await type(tester, 'mailing-address-state', 'MT');
    await type(tester, 'mailing-address-zip', '73001');
    await tester.tap(find.byKey(const Key('mailing-address-save')));
    await tester.pumpAndSettle();
    expect(result.done, isTrue);
    expect(result.picked!.city, 'Exampleville');
  });

  testWidgets('Apt is optional', (tester) async {
    final result = await open(tester, current: stored);
    await type(tester, 'mailing-address-street2', '');
    await tester.tap(find.byKey(const Key('mailing-address-save')));
    await tester.pumpAndSettle();
    expect(result.done, isTrue);
    expect(result.picked!.street2, isEmpty);
  });

  testWidgets('Remove asks first; confirmed, it returns the blank fields, which replaceMailingAddress reads as none',
      (tester) async {
    final result = await open(tester, current: stored);
    await tester.tap(find.byKey(const Key('mailing-address-remove')));
    await tester.pumpAndSettle();
    expect(result.done, isFalse, reason: 'nothing removed until the owner confirms');
    expect(find.text('Remove Mailing Address'), findsOneWidget);

    await tester.tap(find.byKey(const Key('mailing-address-remove-confirm')));
    await tester.pumpAndSettle();
    expect(result.done, isTrue);
    expect(result.picked, same(MailingAddressFields.none));
    expect(replaceMailingAddress([stored], result.picked!, DateTime(2026, 9, 28)), isEmpty);
  });

  testWidgets('Remove, then Cancel on the confirmation: the address stays and the editor is still open',
      (tester) async {
    final result = await open(tester, current: stored);
    await tester.tap(find.byKey(const Key('mailing-address-remove')));
    await tester.pumpAndSettle();
    // The confirmation's Cancel, not the editor's: the editor is behind it.
    await tester.tap(find.descendant(
      of: find.widgetWithText(AlertDialog, 'Remove Mailing Address'),
      matching: find.text('Cancel'),
    ));
    await tester.pumpAndSettle();

    expect(result.done, isFalse);
    expect(find.text('Remove Mailing Address'), findsNothing);
    expect(find.text('Edit Mailing Address'), findsOneWidget);
    expect(fieldText(tester, 'mailing-address-street'), 'PO Box 12');
  });

  testWidgets('Cancel returns nothing', (tester) async {
    final result = await open(tester, current: stored);
    await type(tester, 'mailing-address-city', 'Elsewhere');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result.done, isTrue);
    expect(result.picked, isNull);
  });
}
