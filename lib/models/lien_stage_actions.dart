import 'lien_model.dart';

/// One thing an operator can do to a lien from where it currently stands.
enum LienAction {
  sendNotice,
  fileLien,
  scheduleAuction,
  completeAuction,
  resolve,
  cancel,
}

extension LienActionLabels on LienAction {
  String get label {
    switch (this) {
      case LienAction.sendNotice:
        return 'Send pre-lien notice';
      case LienAction.fileLien:
        return 'File lien with county';
      case LienAction.scheduleAuction:
        return 'Schedule auction';
      case LienAction.completeAuction:
        return 'Mark auction complete';
      case LienAction.resolve:
        return 'Resolve lien';
      case LienAction.cancel:
        return 'Cancel lien';
    }
  }

  /// Actions that end the lien or start a legal step get a confirmation.
  bool get needsConfirmation {
    switch (this) {
      case LienAction.sendNotice:
      case LienAction.completeAuction:
      case LienAction.resolve:
      case LienAction.cancel:
        return true;
      case LienAction.fileLien:
      case LienAction.scheduleAuction:
        // These two collect details in their own dialog, which is the
        // confirmation step.
        return false;
    }
  }
}

/// What may be done to a lien sitting at [stage].
///
/// A lien is a legal sequence: notice, filing, auction, then an outcome. Each
/// step has statutory notice periods behind it, and skipping one is not a UI
/// inconvenience but a defect in the sale of someone's property. So the order
/// is encoded here rather than left to whichever buttons a screen happens to
/// draw, and every stage can still be abandoned or settled.
///
/// Returns an empty list for a lien that has already ended.
List<LienAction> availableLienActions(LienStage stage) {
  switch (stage) {
    case LienStage.notStarted:
      return const [LienAction.sendNotice, LienAction.cancel];
    case LienStage.noticeSent:
      return const [
        LienAction.fileLien,
        LienAction.resolve,
        LienAction.cancel,
      ];
    case LienStage.lienFiled:
      return const [
        LienAction.scheduleAuction,
        LienAction.resolve,
        LienAction.cancel,
      ];
    case LienStage.auctionScheduled:
      return const [
        LienAction.completeAuction,
        LienAction.resolve,
        LienAction.cancel,
      ];
    case LienStage.auctionComplete:
      return const [LienAction.resolve, LienAction.cancel];
    case LienStage.resolved:
    case LienStage.cancelled:
      // Terminal. Reopening a resolved or cancelled lien is not a correction
      // an operator should be able to make by tapping a button.
      return const [];
  }
}

/// The stage [action] moves a lien to, or null when the action opens a dialog
/// that supplies its own details before the stage changes.
LienStage? stageAfter(LienAction action) {
  switch (action) {
    case LienAction.sendNotice:
      return LienStage.noticeSent;
    case LienAction.completeAuction:
      return LienStage.auctionComplete;
    case LienAction.resolve:
      return LienStage.resolved;
    case LienAction.cancel:
      return LienStage.cancelled;
    case LienAction.fileLien:
    case LienAction.scheduleAuction:
      return null;
  }
}
