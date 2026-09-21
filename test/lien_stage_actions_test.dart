import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/lien_model.dart';
import 'package:sfcapp/models/lien_stage_actions.dart';

/// A lien is the legal process for selling a tenant's property to recover
/// unpaid rent. The order of its steps is statutory, so the set of moves
/// available from a stage is not a UI preference.
void main() {
  test('a lien that has not started can only be noticed or abandoned', () {
    expect(
      availableLienActions(LienStage.notStarted),
      [LienAction.sendNotice, LienAction.cancel],
    );
  });

  test('each stage offers exactly one way forward', () {
    const forward = {
      LienStage.notStarted: LienAction.sendNotice,
      LienStage.noticeSent: LienAction.fileLien,
      LienStage.lienFiled: LienAction.scheduleAuction,
      LienStage.auctionScheduled: LienAction.completeAuction,
    };
    forward.forEach((stage, expected) {
      final advancing = availableLienActions(stage)
          .where((a) => a != LienAction.resolve && a != LienAction.cancel)
          .toList();
      expect(advancing, [expected], reason: 'from $stage');
    });
  });

  test('no stage lets the operator skip a step', () {
    // Filing before notice, or auctioning before filing, is the failure that
    // costs a facility the sale. Nothing may offer a step that is more than
    // one place ahead.
    expect(
      availableLienActions(LienStage.notStarted),
      isNot(contains(LienAction.scheduleAuction)),
    );
    expect(
      availableLienActions(LienStage.notStarted),
      isNot(contains(LienAction.fileLien)),
    );
    expect(
      availableLienActions(LienStage.noticeSent),
      isNot(contains(LienAction.scheduleAuction)),
    );
    expect(
      availableLienActions(LienStage.noticeSent),
      isNot(contains(LienAction.completeAuction)),
    );
    expect(
      availableLienActions(LienStage.lienFiled),
      isNot(contains(LienAction.completeAuction)),
    );
  });

  test('a live lien can always be settled or abandoned', () {
    for (final stage in [
      LienStage.noticeSent,
      LienStage.lienFiled,
      LienStage.auctionScheduled,
      LienStage.auctionComplete,
    ]) {
      final actions = availableLienActions(stage);
      expect(actions, contains(LienAction.resolve), reason: 'from $stage');
      expect(actions, contains(LienAction.cancel), reason: 'from $stage');
    }
    // notStarted can be abandoned but has nothing to settle yet.
    expect(availableLienActions(LienStage.notStarted),
        contains(LienAction.cancel));
  });

  test('a finished lien offers nothing', () {
    expect(availableLienActions(LienStage.resolved), isEmpty);
    expect(availableLienActions(LienStage.cancelled), isEmpty);
  });

  test('every stage is covered, so a new one cannot be forgotten', () {
    for (final stage in LienStage.values) {
      expect(() => availableLienActions(stage), returnsNormally);
    }
  });

  group('stageAfter', () {
    test('direct transitions land where the label says', () {
      expect(stageAfter(LienAction.sendNotice), LienStage.noticeSent);
      expect(stageAfter(LienAction.completeAuction), LienStage.auctionComplete);
      expect(stageAfter(LienAction.resolve), LienStage.resolved);
      expect(stageAfter(LienAction.cancel), LienStage.cancelled);
    });

    test('the two that collect details defer their stage change', () {
      // Filing needs a lien number and county; an auction needs a date and
      // company. Returning null is what sends these through their dialog
      // instead of straight to updateLienStage.
      expect(stageAfter(LienAction.fileLien), isNull);
      expect(stageAfter(LienAction.scheduleAuction), isNull);
    });

    test('an action with no stage is exactly one that opens a dialog', () {
      for (final action in LienAction.values) {
        final opensDialog = action == LienAction.fileLien ||
            action == LienAction.scheduleAuction;
        expect(stageAfter(action) == null, opensDialog, reason: '$action');
      }
    });
  });

  test('destructive and legally significant steps are confirmed', () {
    expect(LienAction.sendNotice.needsConfirmation, isTrue);
    expect(LienAction.completeAuction.needsConfirmation, isTrue);
    expect(LienAction.resolve.needsConfirmation, isTrue);
    expect(LienAction.cancel.needsConfirmation, isTrue);
    // These two confirm inside their own detail dialog instead.
    expect(LienAction.fileLien.needsConfirmation, isFalse);
    expect(LienAction.scheduleAuction.needsConfirmation, isFalse);
  });

  test('every action has a label a person can read', () {
    for (final action in LienAction.values) {
      expect(action.label.trim(), isNotEmpty, reason: '$action');
    }
  });
}
