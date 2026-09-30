import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
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

Map<String, dynamic> _refund(String stripeRefundId, double amount, {String? referencePi, String? metaPi}) => {
      '_id': 'refund_$stripeRefundId',
      'type': 'refund',
      'amount': amount,
      'status': 'posted',
      if (referencePi != null) 'referenceId': referencePi,
      'metadata': {
        if (referencePi != null) 'stripeRefundId': stripeRefundId,
        if (metaPi != null) ...{'paymentIntentId': metaPi, 'refundId': stripeRefundId},
      },
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

    Future<CardRefundOutcome> run(_FakeProcessRefund fake, {double amount = 50, List<Map<String, dynamic>>? ledger}) =>
        MoveOutCardRefund.refund(
          facilityId: 'fac-1',
          tenantId: 'tenant-1',
          contractId: 'contract-1',
          amount: amount,
          rows: ledger ?? rows,
          call: fake.call,
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
      expect(
        outcome.ownerAlert,
        endsWith(r'refund $50.00 to their card in your Stripe dashboard, then record it on their ledger '
            r'with Add entry, type Refund, amount $50.00.'),
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
      final outcome = await run(fake, amount: 80);
      expect(fake.calls.map((c) => c['referenceId']), ['pi_test_sep', 'pi_test_aug']);
      expect(outcome.status, CardRefundStatus.partial);
      expect(outcome.refunded, 30);
      expect(outcome.leftOnLedger, 50);
      final alert = outcome.ownerAlert!;
      expect(alert, startsWith(r'The app refunded $30.00 to their card through Stripe. The other $50.00 was not refunded: '
          'Failed to process refund: Card refund failed: charge already refunded. No refund was issued.'));
      expect(alert, contains('look up their payment in your Stripe dashboard'));
      expect(alert, contains(r'Add entry, type Refund, amount $50.00'));
      expect(outcome.contractRecord()['status'], 'partial');
      expect(outcome.contractRecord()['refunds'], hasLength(1));
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
      // processRefund keys a refund by charge and amount; within a day the
      // same amount on the same charge comes back as the earlier refund.
      final fake = _FakeProcessRefund([
        {'success': true, 'stripeRefundId': 're_test_earlier'},
      ]);
      final outcome = await run(fake, amount: 10, ledger: [
        ...rows,
        _refund('re_test_earlier', 10, referencePi: 'pi_test_jul'),
      ]);
      expect(outcome.status, CardRefundStatus.notMade);
      expect(outcome.ownerAlert, contains('re_test_earlier'));
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
