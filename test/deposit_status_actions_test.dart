import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/deposit_model.dart';
import 'package:sfcapp/models/deposit_status_actions.dart';

/// A deposit batch is money leaving the drawer for a bank. Its status is what
/// reconciliation reads, so the order of the steps is bookkeeping, not UI.
void main() {
  test('a pending batch can be taken to the bank or abandoned', () {
    expect(
      availableDepositActions(DepositStatus.pending),
      [DepositAction.markDeposited, DepositAction.cancel],
    );
  });

  test('a batch cannot be reconciled before it has been deposited', () {
    // Matching a bank statement line to a batch that never reached the bank
    // leaves the books describing something that did not happen.
    expect(
      availableDepositActions(DepositStatus.pending),
      isNot(contains(DepositAction.reconcile)),
    );
  });

  test('a deposited batch can be reconciled or corrected', () {
    expect(
      availableDepositActions(DepositStatus.deposited),
      [DepositAction.reconcile, DepositAction.cancel],
    );
  });

  test('a batch cannot be deposited twice', () {
    expect(
      availableDepositActions(DepositStatus.deposited),
      isNot(contains(DepositAction.markDeposited)),
    );
  });

  test('a settled batch offers nothing', () {
    expect(availableDepositActions(DepositStatus.reconciled), isEmpty);
    expect(availableDepositActions(DepositStatus.cancelled), isEmpty);
  });

  test('a reconciled batch cannot be cancelled from a button', () {
    // It is already matched to a bank line. Undoing that silently would put
    // the books and the statement out of agreement with no record of why.
    expect(
      availableDepositActions(DepositStatus.reconciled),
      isNot(contains(DepositAction.cancel)),
    );
  });

  test('every status is covered, so a new one cannot be forgotten', () {
    for (final status in DepositStatus.values) {
      expect(() => availableDepositActions(status), returnsNormally);
    }
  });

  group('statusAfter', () {
    test('direct transitions land where the label says', () {
      expect(statusAfter(DepositAction.markDeposited), DepositStatus.deposited);
      expect(statusAfter(DepositAction.cancel), DepositStatus.cancelled);
    });

    test('reconciling defers, because it collects bank details first', () {
      expect(statusAfter(DepositAction.reconcile), isNull);
    });
  });

  test('every action has a label a person can read', () {
    for (final action in DepositAction.values) {
      expect(action.label.trim(), isNotEmpty, reason: '$action');
    }
  });
}
