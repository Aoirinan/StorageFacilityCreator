import 'deposit_model.dart';

/// One thing an operator can do to a deposit batch from where it stands.
enum DepositAction {
  markDeposited,
  reconcile,
  cancel,
}

extension DepositActionLabels on DepositAction {
  String get label {
    switch (this) {
      case DepositAction.markDeposited:
        return 'Mark deposited';
      case DepositAction.reconcile:
        return 'Reconcile with bank';
      case DepositAction.cancel:
        return 'Cancel deposit';
    }
  }
}

/// What may be done to a deposit sitting at [status].
///
/// A deposit batch is money leaving the drawer and arriving at a bank, and the
/// order matters for reconciliation: a batch is prepared, taken to the bank,
/// then matched against the statement. Reconciling something never deposited,
/// or cancelling a batch already matched to a bank line, both leave the books
/// describing something that did not happen.
///
/// Returns an empty list once the batch has settled one way or the other.
List<DepositAction> availableDepositActions(DepositStatus status) {
  switch (status) {
    case DepositStatus.pending:
      return const [DepositAction.markDeposited, DepositAction.cancel];
    case DepositStatus.deposited:
      // Cancelling is still allowed here: the batch may have been recorded as
      // deposited in error, and nothing has been matched to a statement yet.
      return const [DepositAction.reconcile, DepositAction.cancel];
    case DepositStatus.reconciled:
    case DepositStatus.cancelled:
      // Terminal. A reconciled batch is matched to a bank line; undoing that
      // from a button would put the books and the statement out of agreement
      // with no record of why.
      return const [];
  }
}

/// The status [action] moves a batch to, or null when the action opens a
/// dialog that collects bank details before the status changes.
DepositStatus? statusAfter(DepositAction action) {
  switch (action) {
    case DepositAction.markDeposited:
      return DepositStatus.deposited;
    case DepositAction.cancel:
      return DepositStatus.cancelled;
    case DepositAction.reconcile:
      return null;
  }
}
