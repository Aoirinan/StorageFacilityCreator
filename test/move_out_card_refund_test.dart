import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/audit_service.dart';
import 'package:sfcapp/services/move_out_card_refund.dart';
import 'package:sfcapp/services/move_out_service.dart';

/// A move-out's card refund. processMoveOut no longer records one (nothing
/// there refunds a card) and told the owner Stripe's webhook would record
/// the refund they made in Stripe, which it does not for an online move-in
/// payment or a checkout-link payment. The screen now makes it through
/// processRefund against the tenant's card payments, and says, in words
/// that stay on screen, what it could not refund.
///
/// Invented data throughout: this repository is public.
Map<String, dynamic> _payment(
  String id,
  double amount, {
  String? pi,
  String? referencePi,
  DateTime? on,
  String status = 'posted',
  Map<String, dynamic> extra = const {},
}) =>
    {
      '_id': id,
      'type': 'payment',
      'amount': -amount,
      'status': status,
      if (referencePi != null) 'referenceId': referencePi,
      'metadata': {if (pi != null) 'paymentIntentId': pi, ...extra},
      if (on != null) 'entryDate': Timestamp.fromDate(on),
    };

Map<String, dynamic> _refund(
  String stripeRefundId,
  double amount, {
  String? referencePi,
  String? metaPi,
  DateTime? at,
}) =>
    {
      '_id': 'refund_$stripeRefundId',
      'type': 'refund',
      'amount': amount,
      'status': 'posted',
      if (referencePi != null) 'referenceId': referencePi,
      'metadata': {
        if (referencePi != null) 'stripeRefundId': stripeRefundId,
        if (metaPi != null) ...{'paymentIntentId': metaPi, 'refundId': stripeRefundId},
      },
      if (at != null) 'createdAt': Timestamp.fromDate(at),
    };

/// processRefund, faked: answers from [answers] in turn and records each call.
class _FakeProcessRefund {
  _FakeProcessRefund(this.answers);

  final List<Object> answers;
  final calls = <Map<String, dynamic>>[];

  Future<Map<String, dynamic>> call(Map<String, dynamic> payload) async {
    calls.add(payload);
    final answer = answers[calls.length - 1];
    if (answer is Exception) throw answer;
    return answer as Map<String, dynamic>;
  }
}

void main() {
  final sep = DateTime(2026, 9, 3);
  final aug = DateTime(2026, 8, 1);
  final jul = DateTime(2026, 7, 1);

  group('the card payments the app can refund', () {
    test('payments naming a PaymentIntent, newest first, less refunds already made against each', () {
      final rows = [
        // Online move-in: the id in referenceId and metadata.
        _payment('m1', 60, pi: 'pi_test_movein', referencePi: 'pi_test_movein', on: jul),
        // Autopay / the webhook: payment_<pi>.
        _payment('payment_pi_test_aug', 40, pi: 'pi_test_aug', on: aug),
        _payment('payment_pi_test_sep', 40, pi: 'pi_test_sep', on: sep),
        // Cash: no PaymentIntent, not refundable here.
        _payment('cash1', 100, on: sep),
        // A refund processRefund made against August (referenceId), and the
        // webhook's copy of the same refund (one doc id, counted once).
        _refund('re_test_1', 15, referencePi: 'pi_test_aug'),
        _refund('re_test_1', 15, metaPi: 'pi_test_aug'),
        // One made in the Stripe dashboard against the move-in payment.
        _refund('re_test_2', 60, metaPi: 'pi_test_movein'),
      ];
      final payments = MoveOutCardRefund.refundablePayments(rows);
      expect(payments.map((p) => (p.paymentIntentId, p.refundable)), [
        ('pi_test_sep', 40.0),
        ('pi_test_aug', 25.0),
      ]);
      expect(payments.first.paidOn, sep);
    });

    test('a payment recorded twice counts once; voided and dispute payments are left out', () {
      final rows = [
        _payment('a', 50, pi: 'pi_test_dup', on: aug),
        _payment('b', 50, referencePi: 'pi_test_dup', on: aug),
        _payment('c', 70, pi: 'pi_test_voided', status: 'voided'),
        _payment('d', 30, pi: 'pi_test_dispute', extra: {'disputeId': 'dp_test_1'}),
        _payment('e', 20, pi: 'not_a_payment_intent'),
      ];
      final payments = MoveOutCardRefund.refundablePayments(rows);
      expect(payments.map((p) => (p.paymentIntentId, p.refundable)), [('pi_test_dup', 50.0)]);
    });

    test('the refund is split newest first, never more than a payment has left', () {
      final payments = [
        const RefundableCardPayment(paymentIntentId: 'pi_new', refundable: 30),
        const RefundableCardPayment(paymentIntentId: 'pi_old', refundable: 100),
      ];
      final both = MoveOutCardRefund.plan(amount: 50, payments: payments);
      expect(both.slices.map((s) => (s.paymentIntentId, s.amount)), [('pi_new', 30.0), ('pi_old', 20.0)]);
      expect(both.uncovered, 0);

      final one = MoveOutCardRefund.plan(amount: 12.5, payments: payments);
      expect(one.slices.map((s) => (s.paymentIntentId, s.amount)), [('pi_new', 12.5)]);

      final short = MoveOutCardRefund.plan(amount: 200, payments: payments);
      expect(short.covered, 130);
      expect(short.uncovered, 70);

      expect(MoveOutCardRefund.plan(amount: 50, payments: const []).slices, isEmpty);
    });

    test('the screen says beforehand what the app will refund, and what it cannot', () {
      final plan = MoveOutCardRefund.plan(amount: 50, payments: [
        RefundableCardPayment(paymentIntentId: 'pi_new', refundable: 30, paidOn: sep),
        const RefundableCardPayment(paymentIntentId: 'pi_old', refundable: 5),
      ]);
      expect(
        MoveOutCardRefund.preview(plan),
        r'When you complete the move-out, the app refunds $30.00 to their card payment of Sep 3, 2026, '
        r'$5.00 to a card payment through Stripe. Their card payments cannot take the other $15.00: '
        'it stays on their ledger as a credit for you to refund in Stripe.',
      );
      expect(
        MoveOutCardRefund.preview(MoveOutCardRefund.plan(amount: 50, payments: const [])),
        startsWith('The app found no card payment from this tenant that it can refund.'),
      );
    });
  });

  group('making the refund through processRefund', () {
    final rows = [
      _payment('payment_pi_test_sep', 30, pi: 'pi_test_sep', on: sep),
      _payment('payment_pi_test_aug', 40, pi: 'pi_test_aug', on: aug),
      _payment('payment_pi_test_jul', 40, pi: 'pi_test_jul', on: jul),
    ];

    Future<CardRefundOutcome> run(
      _FakeProcessRefund fake, {
      double amount = 50,
      List<Map<String, dynamic>>? ledger,
      Future<List<Map<String, dynamic>>> Function()? reread,
      String contractId = 'contract-1',
    }) =>
        MoveOutCardRefund.refund(
          facilityId: 'fac-1',
          tenantId: 'tenant-1',
          contractId: contractId,
          amount: amount,
          rows: ledger ?? rows,
          call: fake.call,
          reread: reread,
        );

    test('all of it: one refund per payment, newest first, and nothing for the owner to do', () async {
      final fake = _FakeProcessRefund([
        {'success': true, 'stripeRefundId': 're_test_a'},
        {'success': true, 'stripeRefundId': 're_test_b'},
      ]);
      final outcome = await run(fake);
      expect(fake.calls, [
        {
          'facilityId': 'fac-1',
          'tenantId': 'tenant-1',
          'amount': 30.0,
          'refundMethod': 'creditCard',
          'referenceId': 'pi_test_sep',
          'requestId': 'mo_contract-1_pi_test_sep',
        },
        {
          'facilityId': 'fac-1',
          'tenantId': 'tenant-1',
          'amount': 20.0,
          'refundMethod': 'creditCard',
          'referenceId': 'pi_test_aug',
          'requestId': 'mo_contract-1_pi_test_aug',
        },
      ]);
      expect(outcome.status, CardRefundStatus.refunded);
      expect(outcome.refunded, 50);
      expect(outcome.leftOnLedger, 0);
      expect(outcome.ownerAlert, isNull);
      expect(outcome.contractRecord(), {
        'status': 'refunded',
        'requested': 50.0,
        'refunded': 50.0,
        'leftOnLedger': 0.0,
        'refunds': [
          {'paymentIntentId': 'pi_test_sep', 'stripeRefundId': 're_test_a', 'amount': 30.0},
          {'paymentIntentId': 'pi_test_aug', 'stripeRefundId': 're_test_b', 'amount': 20.0},
        ],
        'reason': null,
      });
    });

    test('no card payment to refund: nothing is called, and the owner is told to refund in Stripe and record it', () async {
      final fake = _FakeProcessRefund([]);
      final outcome = await run(fake, ledger: [_payment('cash1', 100, on: sep)]);
      expect(fake.calls, isEmpty);
      expect(outcome.status, CardRefundStatus.notMade);
      expect(outcome.noRefundablePayment, isTrue);
      expect(outcome.leftOnLedger, 50);
      expect(outcome.ownerAlert, contains('The app found no card payment from this tenant that it can refund'));
      expect(outcome.ownerAlert, contains(r'The $50.00 stays on their ledger as a credit.'));
      // Stripe records a dashboard refund on the ledger itself when the
      // payment names the tenant, so the owner looks for that row before
      // adding one.
      expect(
        outcome.ownerAlert,
        endsWith(r'refund $50.00 to their card in your Stripe dashboard. Wait a minute, then look at '
            'their ledger: Stripe records some card refunds there itself, as a new "Refund for charge …" '
            r'row for that amount. Only if none has appeared, record it with Add entry, type Refund, '
            r'amount $50.00.'),
      );
      expect(outcome.contractRecord()['reason'], 'no refundable card payment');
    });

    test('a refund that fails stops the rest: a timed-out call may still have refunded', () async {
      final fake = _FakeProcessRefund([
        {'success': true, 'stripeRefundId': 're_test_a'},
        FirebaseFunctionsException(
          code: 'internal',
          message: 'Failed to process refund: Card refund failed: charge already refunded. No refund was issued.',
        ),
        {'success': true, 'stripeRefundId': 're_test_never'},
      ]);
      // The ledger read again shows nothing new for August.
      final outcome = await run(fake, amount: 80, reread: () async => rows);
      expect(fake.calls.map((c) => c['referenceId']), ['pi_test_sep', 'pi_test_aug']);
      expect(outcome.status, CardRefundStatus.partial);
      expect(outcome.uncertain, isTrue);
      expect(outcome.refunded, 30);
      expect(outcome.leftOnLedger, 50);
      // Not "not made": the call that failed may have refunded it.
      expect(outcome.alertTitle, 'Card refund only partly confirmed');
      final alert = outcome.ownerAlert!;
      expect(alert, startsWith(r'The app refunded $30.00 to their card through Stripe. The other $50.00 may not have '
          'been refunded: Failed to process refund: Card refund failed: charge already refunded. No refund was issued.'));
      // The ledger is where a refund the failed call made shows up, and it
      // is not recorded a second time.
      expect(alert, contains('The call that failed may still have refunded their card'));
      expect(alert, contains('wait a minute, then look at their ledger for a "Refund for charge …" row from today '
          'besides the refunds above'));
      expect(alert, contains('do not record it again'));
      expect(alert, contains('Only if none has appeared, record it with Add entry, type Refund.'));
      expect(outcome.contractRecord()['status'], 'partial');
      expect(outcome.contractRecord()['refunds'], hasLength(1));
    });

    test('a call that failed but refunded after all (its row is on the ledger read again) counts as made', () async {
      // The answer timed out, but processRefund had refunded August and
      // written refund_re_test_late against it.
      final fake = _FakeProcessRefund([
        {'success': true, 'stripeRefundId': 're_test_a'},
        FirebaseFunctionsException(code: 'deadline-exceeded', message: 'deadline-exceeded'),
        {'success': true, 'stripeRefundId': 're_test_c'},
      ]);
      var rereads = 0;
      final outcome = await run(fake, amount: 80, reread: () async {
        rereads++;
        return [
          ...rows,
          _refund('re_test_a', 30, referencePi: 'pi_test_sep'),
          _refund('re_test_late', 40, referencePi: 'pi_test_aug'),
        ];
      });
      expect(rereads, 1);
      // So the rest goes on to July, as after any refund that was made.
      expect(fake.calls.map((c) => c['referenceId']), ['pi_test_sep', 'pi_test_aug', 'pi_test_jul']);
      expect(fake.calls.map((c) => c['requestId']).toSet(), hasLength(3));
      expect(outcome.status, CardRefundStatus.refunded);
      expect(outcome.ownerAlert, isNull);
      expect(outcome.refunds.map((r) => (r.paymentIntentId, r.stripeRefundId, r.amount)), [
        ('pi_test_sep', 're_test_a', 30.0),
        ('pi_test_aug', 're_test_late', 40.0),
        ('pi_test_jul', 're_test_c', 10.0),
      ]);
    });

    test('the ledger read again counts only a new refund of that payment for that amount', () {
      const CardRefundSlice slice = (paymentIntentId: 'pi_test_aug', amount: 40.0, paidOn: null);
      final before = {'re_test_old'};
      // One already there before the call, another payment's, another
      // amount, or voided: none is the refund this call was making.
      final rows = [
        _refund('re_test_old', 40, referencePi: 'pi_test_aug'),
        _refund('re_test_other', 40, referencePi: 'pi_test_sep'),
        _refund('re_test_small', 15, metaPi: 'pi_test_aug'),
        {..._refund('re_test_void', 40, referencePi: 'pi_test_aug'), 'status': 'voided'},
      ];
      expect(MoveOutCardRefund.landedRefund(rows, slice: slice, known: before), isNull);
      // The webhook's copy of the same refund is found too.
      final landed = MoveOutCardRefund.landedRefund(
        [...rows, _refund('re_test_new', 40, metaPi: 'pi_test_aug')],
        slice: slice,
        known: before,
      );
      expect(landed, (paymentIntentId: 'pi_test_aug', stripeRefundId: 're_test_new', amount: 40.0));
    });

    test('a refusal before processRefund reaches Stripe is not one that may have refunded', () async {
      final fake = _FakeProcessRefund([
        FirebaseFunctionsException(code: 'resource-exhausted', message: 'Rate limit exceeded for processRefund.'),
      ]);
      final outcome = await run(fake, reread: () async => rows);
      expect(outcome.uncertain, isFalse);
      expect(outcome.ownerAlert, startsWith(r'The $50.00 was not refunded: Rate limit exceeded for processRefund.'));
      expect(outcome.ownerAlert, contains(r'To refund it: refund $50.00 to their card in your Stripe dashboard.'));
      expect(outcome.ownerAlert, isNot(contains('may still have refunded')));
      // Its own "No refund was issued" comes back 'internal', as does a
      // refund whose ledger row failed to write, so that one may have.
      final internal = await run(
        _FakeProcessRefund([FirebaseFunctionsException(code: 'internal', message: 'No refund was issued.')]),
        reread: () async => rows,
      );
      expect(internal.uncertain, isTrue);
    });

    test('a ledger that cannot be read again leaves the failed call unconfirmed', () async {
      final fake = _FakeProcessRefund([Exception('connection reset')]);
      final outcome = await run(fake, reread: () async => throw Exception('offline'));
      expect(outcome.status, CardRefundStatus.notMade);
      expect(outcome.uncertain, isTrue);
      expect(outcome.alertTitle, 'Card refund not confirmed');
      expect(outcome.ownerAlert, startsWith(r'The $50.00 may not have been refunded: Exception: connection reset'));
      expect(outcome.ownerAlert, contains('may still have refunded their card'));
      expect(outcome.ownerAlert, isNot(contains('was not refunded')));
    });

    test('a facility with no connected Stripe account: processRefund only logs it, which is not a refund', () async {
      // Its answer then has a made-up refundId and no stripeRefundId.
      final fake = _FakeProcessRefund([
        {'success': true, 'refundId': 'refund-123', 'message': 'Refund logged for processing'},
      ]);
      final outcome = await run(fake);
      expect(outcome.status, CardRefundStatus.notMade);
      expect(outcome.refunded, 0);
      expect(outcome.ownerAlert, contains('Stripe account is not connected'));
      expect(fake.calls, hasLength(1));
    });

    test('a refund Stripe hands back that is already on the ledger was not a new one', () async {
      // A processRefund from before the request id keys a refund by charge
      // and amount: a tenant moved out of two units at one rate on the same
      // day had the second refund come back as the first.
      final fake = _FakeProcessRefund([
        {'success': true, 'stripeRefundId': 're_test_earlier'},
      ]);
      final outcome = await run(fake, amount: 10, ledger: [
        ...rows,
        _refund('re_test_earlier', 10, referencePi: 'pi_test_jul'),
      ]);
      expect(outcome.status, CardRefundStatus.notMade);
      expect(outcome.uncertain, isFalse);
      expect(outcome.knownRefundId, 're_test_earlier');
      final alert = outcome.ownerAlert!;
      expect(alert, startsWith(r'No new refund was made for the $10.00: Stripe answered with a refund that is '
          'already on their ledger (re_test_earlier).'));
      // With request ids that refund can be this move-out's, made by an
      // earlier press: "it is not this one" sent the owner to refund it
      // again by hand. They look at the ledger first.
      expect(alert, isNot(contains('not this one')));
      expect(alert, contains(r'Before refunding anything by hand, look at their ledger for "Refund for charge …" '
          r'rows from the move-out on. Whatever of the $10.00 they do not cover is still owed'));
      expect(alert, contains('refund that to their card in your Stripe dashboard'));
      // It used to say a refund already showing in Stripe need only be
      // recorded: the owner found the other unit's refund there, recorded
      // it, and the tenant was paid $10 less than their ledger said.
      expect(alert, isNot(contains('already shows there')));
      expect(alert, isNot(contains('only record')));
    });

    test('no alert tells the owner to record a refund they find in Stripe', () {
      final alerts = [
        const CardRefundOutcome(requested: 50, noRefundablePayment: true),
        const CardRefundOutcome(requested: 50, failure: 'x'),
        const CardRefundOutcome(requested: 50, failure: 'x', uncertain: true),
        const CardRefundOutcome(
          requested: 50,
          refunds: [(paymentIntentId: 'pi_test_1', stripeRefundId: 're_test_1', amount: 20)],
        ),
        const CardRefundOutcome(requested: 50, failure: 'x', knownRefundId: 're_test_1'),
        const CardRefundOutcome(requested: 50, failure: 'x', refundSinceOffer: true),
      ].map((o) => o.ownerAlert!);
      for (final alert in alerts) {
        expect(alert, isNot(contains('already shows there')));
        expect(alert, contains('"Refund for charge …"'));
      }
    });

    test("the same move-out's retry sends the same request ids; another unit's move-out sends others", () async {
      final first = _FakeProcessRefund([
        {'success': true, 'stripeRefundId': 're_test_a'},
        {'success': true, 'stripeRefundId': 're_test_b'},
      ]);
      final again = _FakeProcessRefund([
        {'success': true, 'stripeRefundId': 're_test_a'},
        {'success': true, 'stripeRefundId': 're_test_b'},
      ]);
      final otherUnit = _FakeProcessRefund([
        {'success': true, 'stripeRefundId': 're_test_c'},
        {'success': true, 'stripeRefundId': 're_test_d'},
      ]);
      await run(first);
      await run(again);
      await run(otherUnit, contractId: 'contract-2');
      List<Object?> ids(_FakeProcessRefund f) => [for (final c in f.calls) c['requestId']];
      expect(ids(again), ids(first));
      expect(ids(otherUnit), ['mo_contract-2_pi_test_sep', 'mo_contract-2_pi_test_aug']);
      // The same amounts too: processRefund keys on charge, amount and id.
      expect([for (final c in again.calls) c['amount']], [for (final c in first.calls) c['amount']]);
    });

    test("processRefund's request id is one per move-out and payment, within its limits", () {
      final id = MoveOutCardRefund.requestId('contract-1', 'pi_test_sep');
      expect(id, 'mo_contract-1_pi_test_sep');
      expect(RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(id), isTrue);
      final long = MoveOutCardRefund.requestId('c/${'x' * 80}', 'pi_${'y' * 24}');
      expect(long.length, 64);
      expect(RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(long), isTrue);
    });
  });

  group("the move-out screen's answer", () {
    final calculation = MoveOutCalculation(
      lineItems: const [],
      currentBalance: 0,
      newCharges: -36.67,
      finalBalance: -36.67,
      refundAmount: 36.67,
    );
    final server = {
      'success': true,
      'rentNotice': null,
      'rentWarning': "Check Ada Park's rent: they now hold unit 102; their rent is \$100.00.",
      'refundRecorded': false,
      'refundPosted': false,
      'refundWarning': r'The $36.67 card refund was not made by the move-out, and it stays on their ledger as a credit.',
      'cardRefundDue': 36.67,
    };

    test('a card refund left to the screen: the server warning that it was not made is not shown', () {
      expect(MoveOutService.cardRefundDue(server), 36.67);
      final result = MoveOutService.moveOutResultFromServer(server, calculation);
      expect(result.refund, isNull);
      expect(result.warning, "Check Ada Park's rent: they now hold unit 102; their rent is \$100.00.");
      // Never on a retry, nor from a server that sends none (it recorded
      // the refund itself and says so in refundPosted).
      expect(MoveOutService.cardRefundDue({...server, 'alreadyCompleted': true}), 0);
      expect(MoveOutService.cardRefundDue({'success': true, 'refundPosted': true}), 0);
      expect(MoveOutService.cardRefundDue({'cardRefundDue': 'x'}), 0);
    });

    test('refunded in full: shown as refunded to their card, nothing to act on', () {
      final result = MoveOutService.withCardRefund(
        MoveOutService.moveOutResultFromServer(server, calculation),
        const CardRefundOutcome(
          requested: 36.67,
          refunds: [(paymentIntentId: 'pi_test_1', stripeRefundId: 're_test_1', amount: 36.67)],
        ),
      );
      expect(result.success, isTrue);
      expect(result.refund, 36.67);
      expect(result.refundByCard, isTrue);
      expect(result.refundAlert, isNull);
      expect(result.refundAlertTitle, isNull);
      expect(result.warning, startsWith("Check Ada Park's rent"));
    });

    test('not refunded: nothing shown as refunded, and the alert that stays on screen says what to do', () {
      final result = MoveOutService.withCardRefund(
        MoveOutService.moveOutResultFromServer(server, calculation),
        const CardRefundOutcome(requested: 36.67, noRefundablePayment: true),
      );
      expect(result.refund, isNull);
      expect(result.refundByCard, isFalse);
      expect(result.refundAlertTitle, 'Card refund not made');
      expect(result.refundAlert, contains(r'Add entry, type Refund, amount $36.67'));

      final partial = MoveOutService.withCardRefund(
        MoveOutService.moveOutResultFromServer(server, calculation),
        const CardRefundOutcome(
          requested: 36.67,
          refunds: [(paymentIntentId: 'pi_test_1', stripeRefundId: 're_test_1', amount: 20)],
          failure: 'Card refund failed.',
        ),
      );
      expect(partial.refund, 20);
      expect(partial.refundAlertTitle, 'Card refund only partly made');
      expect(partial.refundAlert, contains(r'The other $16.67 was not refunded: Card refund failed.'));
    });
  });

  group('a card refund an earlier press left pending', () {
    final movedOut = DateTime.utc(2026, 9, 23, 15);
    final PendingCardRefund pending = (requested: 36.67, since: movedOut);
    final rows = [
      _payment('payment_pi_test_sep', 40, pi: 'pi_test_sep', on: sep),
      // Refunded before the move-out: not part of this one.
      _refund('re_test_old', 3.33, referencePi: 'pi_test_sep', at: DateTime.utc(2026, 9, 10)),
    ];
    final calculation = MoveOutCalculation(
      lineItems: const [],
      currentBalance: 0,
      newCharges: -36.67,
      finalBalance: -36.67,
      refundAmount: 36.67,
    );

    test("a retry's answer carries it; a first press, a finished refund or an older server do not", () {
      final repeat = {
        'success': true,
        'alreadyCompleted': true,
        'cardRefundDue': 0,
        'message': 'This move-out was already completed, so nothing was charged or changed again.',
        'pendingCardRefund': {'requested': 36.67, 'since': '2026-09-23T15:00:00.000Z'},
      };
      expect(MoveOutService.pendingCardRefund(repeat), (requested: 36.67, since: movedOut));
      // Never refunded on its own: nothing is due.
      expect(MoveOutService.cardRefundDue(repeat), 0);
      final result = MoveOutService.moveOutResultFromServer(repeat, calculation);
      expect(result.pendingCardRefund, (requested: 36.67, since: movedOut));
      expect(result.refund, isNull);
      expect(result.warning, contains('already completed'));

      expect(MoveOutService.pendingCardRefund({...repeat, 'pendingCardRefund': null}), isNull);
      expect(MoveOutService.pendingCardRefund({...repeat, 'alreadyCompleted': false}), isNull);
      expect(MoveOutService.pendingCardRefund({'success': true, 'alreadyCompleted': true}), isNull);
      expect(MoveOutService.pendingCardRefund({...repeat, 'pendingCardRefund': {'requested': 0}}), isNull);
      expect(
        MoveOutService.pendingCardRefund({...repeat, 'pendingCardRefund': {'requested': 20, 'since': null}}),
        (requested: 20.0, since: null),
      );
    });

    test('offered when no refund has reached the ledger since the move-out', () {
      final choice = MoveOutCardRefund.pendingChoiceFrom(pending, rows);
      expect(choice.alert, isNull);
      expect(choice.plan!.slices.map((s) => (s.paymentIntentId, s.amount)), [('pi_test_sep', 36.67)]);
      expect(
        MoveOutCardRefund.pendingOffer(choice.plan!),
        r'This move-out was completed earlier, but its $36.67 card refund was not made: the answer to the '
        'first press never reached the app, so it did not refund the card, and no refund has reached '
        'their ledger since.\n\n'
        r'The app can make it now: it refunds $36.67 to their card payment of Sep 3, 2026 through Stripe.',
      );
    });

    test('not offered once a card refund has reached the ledger since: part of it may be made', () {
      final since = [
        ...rows,
        _refund('re_test_partway', 20, referencePi: 'pi_test_sep', at: movedOut.add(const Duration(seconds: 5))),
      ];
      expect(MoveOutCardRefund.mayOfferPending(pending, since), isFalse);
      final choice = MoveOutCardRefund.pendingChoiceFrom(pending, since);
      expect(choice.plan, isNull);
      expect(choice.alert, contains(r'no record that its $36.67 card refund was made'));
      expect(choice.alert, contains('part of it may already be made'));
      expect(choice.alert, contains('Nothing was refunded just now.'));
      expect(choice.alert, contains('"Refund for charge …" rows from the move-out on'));
      // An undated refund row, or a move-out with no time, is not ruled out either.
      expect(
        MoveOutCardRefund.mayOfferPending(pending, [...rows, _refund('re_test_undated', 5, metaPi: 'pi_test_sep')]),
        isFalse,
      );
      expect(MoveOutCardRefund.mayOfferPending((requested: 36.67, since: null), rows), isFalse);
    });

    test('a refund row naming no Stripe payment counts too: an Add entry refund has none', () {
      // What Add entry, type Refund writes: no referenceId, no metadata. It
      // is the row the alerts ask for after a refund made in Stripe, so the
      // whole refund was offered again once the owner had made it.
      Map<String, dynamic> addEntryRefund(DateTime at) => {
            '_id': 'manual-refund',
            'tenantId': 'tenant-1',
            'type': 'refund',
            'amount': 36.67,
            'status': 'posted',
            'entryDate': Timestamp.fromDate(at),
            'createdAt': Timestamp.fromDate(at),
          };
      final after = [...rows, addEntryRefund(movedOut.add(const Duration(days: 1)))];
      expect(MoveOutCardRefund.mayOfferPending(pending, after), isFalse);
      expect(MoveOutCardRefund.pendingChoiceFrom(pending, after).plan, isNull);
      // One from before the move-out is not part of it; a voided one is not a refund.
      expect(MoveOutCardRefund.mayOfferPending(pending, [...rows, addEntryRefund(DateTime.utc(2026, 9, 1))]), isTrue);
      expect(
        MoveOutCardRefund.mayOfferPending(pending, [
          ...rows,
          {...addEntryRefund(movedOut.add(const Duration(days: 1))), 'status': 'voided'},
        ]),
        isTrue,
      );
    });

    test('a refund that lands between the offer and the press is not made again', () async {
      // Two staff, or a reload and a second press: the other press's $30
      // refund of September lands while this press's offer is open.
      final atOffer = [
        _payment('payment_pi_test_sep', 30, pi: 'pi_test_sep', on: sep),
        _payment('payment_pi_test_aug', 40, pi: 'pi_test_aug', on: aug),
      ];
      final offered = MoveOutCardRefund.pendingChoiceFrom(pending, atOffer).plan!;
      expect(offered.slices.map((s) => (s.paymentIntentId, s.amount)), [('pi_test_sep', 30.0), ('pi_test_aug', 6.67)]);
      final landed = _refund('re_test_first', 30, referencePi: 'pi_test_sep', at: movedOut.add(const Duration(minutes: 2)));
      final atPress = [...atOffer, landed];
      Future<CardRefundOutcome> press(
        _FakeProcessRefund fake,
        List<Map<String, dynamic>> rows, {
        DateTime? pendingSince,
      }) =>
          MoveOutCardRefund.refund(
            facilityId: 'fac-1',
            tenantId: 'tenant-1',
            contractId: 'contract-1',
            amount: pending.requested,
            rows: rows,
            call: fake.call,
            pendingSince: pendingSince,
          );

      // Unchecked, the plan put all of it on August: another request id, so
      // Stripe refunded it a second time.
      final unchecked = _FakeProcessRefund([
        {'success': true, 'stripeRefundId': 're_test_second'},
      ]);
      await press(unchecked, atPress);
      expect(unchecked.calls.map((c) => (c['referenceId'], c['amount'])), [('pi_test_aug', 36.67)]);

      final fake = _FakeProcessRefund([]);
      final outcome = await press(fake, atPress, pendingSince: movedOut);
      expect(fake.calls, isEmpty);
      expect(outcome.refundSinceOffer, isTrue);
      expect(outcome.refunded, 0);
      expect(outcome.alertTitle, 'Card refund may already be made');
      final alert = outcome.ownerAlert!;
      expect(alert, contains('A refund has reached their ledger since the app offered to make it'));
      expect(alert, contains('Nothing was refunded just now.'));
      expect(alert, contains(r'"Refund for charge …" rows from the move-out on. Whatever of the $36.67 they do not '
          'cover is still owed'));

      // Nor when the plan stays on one payment under the same request id:
      // Stripe answered with the first refund, and the owner was told it
      // was not this one and to refund it by hand.
      final roomy = [
        _payment('payment_pi_test_big', 100, pi: 'pi_test_big', on: sep),
        _refund('re_test_first', 36.67, referencePi: 'pi_test_big', at: movedOut.add(const Duration(minutes: 2))),
      ];
      final sameKey = _FakeProcessRefund([
        {'success': true, 'stripeRefundId': 're_test_first'},
      ]);
      expect((await press(sameKey, roomy, pendingSince: movedOut)).refundSinceOffer, isTrue);
      expect(sameKey.calls, isEmpty);

      // With nothing new on the ledger, the offered refund is made as offered.
      final clean = _FakeProcessRefund([
        {'success': true, 'stripeRefundId': 're_test_a'},
        {'success': true, 'stripeRefundId': 're_test_b'},
      ]);
      final made = await press(clean, atOffer, pendingSince: movedOut);
      expect(clean.calls.map((c) => (c['referenceId'], c['amount'])), [('pi_test_sep', 30.0), ('pi_test_aug', 6.67)]);
      expect(made.status, CardRefundStatus.refunded);
    });

    test('refunding it in Stripe themselves takes it off pending, so it is not offered again', () async {
      // processMoveOut sends back only a 'pending' record.
      expect(MoveOutCardRefund.leftToOwnerRecord(36.67), {
        'status': 'manual',
        'requested': 36.67,
        'refunded': 0.0,
        'leftOnLedger': 36.67,
        'refunds': <Map<String, dynamic>>[],
        'reason': 'the owner chose to refund it in Stripe themselves',
      });
      final logged = <AuditLogEntry>[];
      AuditService.recordForTesting = logged.add;
      addTearDown(() => AuditService.recordForTesting = null);
      await MoveOutCardRefund.recordLeftToOwner(
        facilityId: 'fac-1',
        tenantId: 'tenant-1',
        contractId: 'contract-1',
        requested: 36.67,
      );
      expect(logged.map((e) => (e.eventType, e.targetId, e.after?['status'])), [
        ('moveout.cardRefund', 'contract-1', 'manual'),
      ]);
    });

    test('not offered when the app has no card payment to refund', () {
      final choice = MoveOutCardRefund.pendingChoiceFrom(pending, [_payment('cash1', 100, on: sep)]);
      expect(choice.plan, isNull);
      expect(choice.alert, contains('The app found no card payment from this tenant that it can refund.'));
    });

    test("the screen asks before making it, and makes it through the first press's path", () {
      final screen = File('lib/screens/move_out_screen.dart').readAsStringSync();
      expect(screen, contains("Key('move-out-pending-card-refund')"));
      expect(screen, contains("Text('Make the refund')"));
      expect(screen, contains("Text('Refund it in Stripe myself')"));
      expect(screen, contains('if (make != true) {'));
      expect(screen, contains('MoveOutCardRefund.refundAfterMoveOut('));
      expect(screen, contains('contractId: widget.contractId,'));
      // The refund read checks again for one that landed while it asked.
      expect(screen, contains('pendingSince: pending.since,'));
      // "Refund it in Stripe myself" is recorded before the alert.
      final declined = screen.indexOf('if (make != true) {');
      final recorded = screen.indexOf('MoveOutCardRefund.recordLeftToOwner(', declined);
      expect(recorded, greaterThan(declined));
      expect(recorded, lessThan(screen.indexOf('MoveOutCardRefund.pendingAlert(pending.requested)', declined)));
    });
  });

  group('the app path that recorded card refunds twice is gone', () {
    final service = File('lib/services/move_out_service.dart').readAsStringSync();
    final screen = File('lib/screens/move_out_screen.dart').readAsStringSync();

    test('completeMoveOut always goes through processMoveOut, and writes no ledger rows itself', () {
      expect(service, isNot(contains('bool useCloudFunction')));
      expect(service, isNot(contains('if (useCloudFunction)')));
      expect(service, isNot(contains('LedgerService.createLedgerEntry(')));
      expect(service, isNot(contains('_processStripeRefund')));
      expect(service, contains('MoveOutCardRefund.refundAfterMoveOut('));
    });

    test('the card option says the app makes the refund, and the alert is a dialog', () {
      expect(screen, contains("Text('Card (the app refunds it through Stripe)')"));
      expect(screen, isNot(contains("Text('Credit Card Refund')")));
      expect(screen, contains("Key('move-out-card-refund-alert')"));
      expect(screen, contains('barrierDismissible: false'));
    });
  });
}
