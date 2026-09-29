import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/models/security_deposit_model.dart';
import 'package:sfcapp/widgets/security_deposit_dialogs.dart';

// The two dialogs on the tenant page, run on their own: what they prefill,
// what they refuse, and what they hand back. Saving is the service's job
// (security_deposit_settlement_test.dart). All names are made up.

final _today = DateTime(2026, 9, 28);
final _moveIn = DateTime(2026, 9, 1);

SecurityDeposit _held({double amount = 25}) => SecurityDeposit(
      amount: amount,
      receivedDate: SecurityDeposit.noonUtc(_moveIn),
      method: PaymentMethod.check,
      reference: '1234',
      note: 'Covers Unit 12',
    );

/// What a dialog popped with, once it has closed.
class _Opened<T> {
  T? result;
  bool closed = false;
}

/// Opens [dialog] from a button; [_Opened.result] fills in when it closes.
Future<_Opened<T>> _open<T>(WidgetTester tester, Widget dialog) async {
  final opened = _Opened<T>();
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            opened.result = await showDialog<T>(
              context: context,
              builder: (_) => dialog,
            );
            opened.closed = true;
          },
          child: const Text('Open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return opened;
}

String _fieldText(WidgetTester tester, Key key) =>
    tester.widget<TextFormField>(find.byKey(key)).controller!.text;

Future<void> _type(WidgetTester tester, Key key, String text) async {
  await tester.enterText(find.byKey(key), text);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String text) async {
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

void main() {
  group('Security deposit dialog', () {
    testWidgets('with nothing on file: the facility default, move-in date and Cash; no Remove',
        (tester) async {
      final opened = await _open<SecurityDepositEdit>(
        tester,
        SecurityDepositDialog(
          defaultAmount: 25,
          defaultReceivedDate: _moveIn,
          today: _today,
        ),
      );

      expect(find.text('Security deposit'), findsOneWidget);
      expect(_fieldText(tester, const Key('security-deposit-amount')), '25.00');
      expect(find.text('9/1/2026'), findsOneWidget);
      expect(find.text('Cash'), findsOneWidget);
      expect(find.text('Remove'), findsNothing);

      await _type(tester, const Key('security-deposit-reference'), '1234');
      await _type(tester, const Key('security-deposit-note'), 'Covers Unit 12');
      await _tap(tester, 'Save');

      expect(opened.closed, isTrue);
      final save = opened.result as SecurityDepositSave;
      expect(save.amount, 25);
      expect(save.receivedDate, _moveIn);
      expect(save.method, PaymentMethod.cash);
      expect(save.reference, '1234');
      expect(save.note, 'Covers Unit 12');
    });

    testWidgets('with no facility default or move-in date: blank amount, today',
        (tester) async {
      await _open<SecurityDepositEdit>(tester, SecurityDepositDialog(today: _today));
      expect(_fieldText(tester, const Key('security-deposit-amount')), '');
      expect(find.text('9/28/2026'), findsOneWidget);
    });

    testWidgets('a deposit on file is prefilled, and Remove hands back the removal',
        (tester) async {
      final opened = await _open<SecurityDepositEdit>(
        tester,
        SecurityDepositDialog(current: _held(), defaultAmount: 50, today: _today),
      );

      // What is on file wins over the facility default.
      expect(_fieldText(tester, const Key('security-deposit-amount')), '25.00');
      expect(_fieldText(tester, const Key('security-deposit-reference')), '1234');
      expect(_fieldText(tester, const Key('security-deposit-note')), 'Covers Unit 12');
      expect(find.text('Check'), findsOneWidget);
      expect(find.text('9/1/2026'), findsOneWidget);

      await _tap(tester, 'Remove');
      expect(opened.closed, isTrue);
      expect(opened.result, isA<SecurityDepositRemove>());
    });

    testWidgets('a blank or zero amount is refused; the date can be cleared to unknown',
        (tester) async {
      final opened = await _open<SecurityDepositEdit>(
          tester, SecurityDepositDialog(defaultReceivedDate: _moveIn, today: _today));

      await _tap(tester, 'Save');
      expect(find.text('Enter an amount above \$0.'), findsOneWidget);
      expect(opened.closed, isFalse);

      await _type(tester, const Key('security-deposit-amount'), '0');
      await _tap(tester, 'Save');
      expect(find.text('Enter an amount above \$0.'), findsOneWidget);
      expect(opened.closed, isFalse);

      await _type(tester, const Key('security-deposit-amount'), '25');
      await tester.tap(find.byTooltip('Date unknown'));
      await tester.pumpAndSettle();
      expect(find.text('Unknown'), findsOneWidget);
      await _tap(tester, 'Save');

      expect(opened.closed, isTrue);
      final save = opened.result as SecurityDepositSave;
      expect(save.amount, 25);
      expect(save.receivedDate, isNull);
      expect(save.reference, isNull);
      expect(save.note, isNull);
    });

    testWidgets('Cancel hands back nothing', (tester) async {
      final opened = await _open<SecurityDepositEdit>(
          tester, SecurityDepositDialog(defaultAmount: 25, today: _today));
      await _tap(tester, 'Cancel');
      expect(opened.closed, isTrue);
      expect(opened.result, isNull);
    });
  });

  group('Settle security deposit dialog', () {
    testWidgets('defaults to what is owed, up to the deposit, and refunds the rest',
        (tester) async {
      // Owes $10 of a $25 deposit: apply $10, refund $15.
      final opened = await _open<SecurityDepositSettlement>(
          tester, SettleSecurityDepositDialog(deposit: _held(), balance: 10));

      expect(find.text('Deposit held: \$25.00'), findsOneWidget);
      expect(find.text('Current balance: \$10.00 owed'), findsOneWidget);
      expect(_fieldText(tester, const Key('settle-deposit-applied')), '10.00');
      expect(_fieldText(tester, const Key('settle-deposit-refunded')), '15.00');
      expect(find.textContaining('the refund is recorded here, not on the ledger'), findsOneWidget);
      // Refunding, so how it went back is asked.
      expect(find.byKey(const Key('settle-deposit-refund-method')), findsOneWidget);

      await _type(tester, const Key('settle-deposit-refund-reference'), '5678');
      await _tap(tester, 'Settle');

      expect(opened.closed, isTrue);
      final result = opened.result!;
      expect(result.appliedAmount, 10);
      expect(result.refundedAmount, 15);
      expect(result.refundMethod, PaymentMethod.cash);
      expect(result.refundReference, '5678');
    });

    testWidgets('a balance above the deposit applies all of it', (tester) async {
      await _open<SecurityDepositSettlement>(
          tester, SettleSecurityDepositDialog(deposit: _held(), balance: 80));
      expect(_fieldText(tester, const Key('settle-deposit-applied')), '25.00');
      expect(_fieldText(tester, const Key('settle-deposit-refunded')), '0.00');
      // Nothing is refunded, so no refund method is asked for.
      expect(find.byKey(const Key('settle-deposit-refund-method')), findsNothing);
    });

    testWidgets('a credit balance applies none of it', (tester) async {
      await _open<SecurityDepositSettlement>(
          tester, SettleSecurityDepositDialog(deposit: _held(), balance: -40));
      expect(find.text('Current balance: \$40.00 credit'), findsOneWidget);
      expect(_fieldText(tester, const Key('settle-deposit-applied')), '0.00');
      expect(_fieldText(tester, const Key('settle-deposit-refunded')), '25.00');
    });

    testWidgets('typing one side fills the other; a split that does not add up disables Settle',
        (tester) async {
      final opened = await _open<SecurityDepositSettlement>(
          tester, SettleSecurityDepositDialog(deposit: _held(), balance: 0));

      await _type(tester, const Key('settle-deposit-applied'), '5');
      expect(_fieldText(tester, const Key('settle-deposit-refunded')), '20.00');

      await _type(tester, const Key('settle-deposit-refunded'), '30');
      expect(find.text('The two amounts must add up to \$25.00.'), findsOneWidget);
      final settle = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'Settle'));
      expect(settle.onPressed, isNull);

      await _type(tester, const Key('settle-deposit-refunded'), '20');
      expect(_fieldText(tester, const Key('settle-deposit-applied')), '5.00');
      await _tap(tester, 'Settle');

      expect(opened.closed, isTrue);
      expect(opened.result!.appliedAmount, 5);
      expect(opened.result!.refundedAmount, 20);
    });

    test('the default split never applies more than the deposit or against a credit', () {
      expect(defaultDepositSplit(_held(), 10), (applied: 10.0, refunded: 15.0));
      expect(defaultDepositSplit(_held(), 80), (applied: 25.0, refunded: 0.0));
      expect(defaultDepositSplit(_held(), -40), (applied: 0.0, refunded: 25.0));
      expect(defaultDepositSplit(_held(), 0), (applied: 0.0, refunded: 25.0));
      // Cents: a $12.345 balance applies $12.35 (rounded) and refunds the rest.
      expect(defaultDepositSplit(_held(), 12.345), (applied: 12.35, refunded: 12.65));
    });
  });
}
