import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/providers/ledger_provider.dart';
import 'package:sfcapp/providers/permission_provider.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/screens/ledger_screen.dart';
import 'package:sfcapp/services/audit_service.dart';
import 'package:sfcapp/services/ledger_card_refund.dart';
import 'package:sfcapp/services/permission_service.dart';
import 'package:sfcapp/widgets/card_refund_dialog.dart';

/// The ledger's Refund on a card payment row. The only card refund in the
/// app was the move-out's, so an owner refunding one payment went into
/// Stripe, and the ledger then waited on the webhook to show it. Refund
/// makes it through processRefund, which posts the refund row the webhook
/// converges on.
///
/// Invented data throughout: this repository is public.
final _tenant = TenantModel(
  id: 'tenant-1',
  facilityId: 'fac-1',
  name: 'Pat Example',
  email: 'pat@example.com',
  phone: '',
  unitNumber: 'A-1',
  monthlyRate: 50,
  createdAt: DateTime(2026, 1, 1),
);

final _sep3 = DateTime(2026, 9, 3);

LedgerEntry _entry(
  String id,
  String type,
  double amount, {
  LedgerEntryStatus status = LedgerEntryStatus.posted,
  String? referenceId,
  Map<String, dynamic>? metadata,
  DateTime? on,
  String? description,
}) =>
    LedgerEntry(
      id: id,
      tenantId: _tenant.id,
      facilityId: _tenant.facilityId,
      type: LedgerEntryType.values.firstWhere((t) => t.name == type, orElse: () => LedgerEntryType.otherCharge),
      amount: amount,
      description: description,
      referenceId: referenceId,
      entryDate: on ?? _sep3,
      status: status,
      metadata: metadata,
      createdAt: on ?? _sep3,
      createdBy: 'staff-1',
      storedType: type,
    );

/// A card payment of [amount], as the webhook and autopay write one.
LedgerEntry _card(String id, double amount, String pi, {LedgerEntryStatus status = LedgerEntryStatus.posted}) =>
    _entry(id, 'payment', -amount, status: status, metadata: {'paymentIntentId': pi});

/// processRefund's refund row: `refund_<id>`, referenceId the PaymentIntent.
LedgerEntry _appRefund(String refundId, double amount, String pi) => _entry(
      'refund_$refundId',
      'refund',
      amount,
      referenceId: pi,
      description: 'Refund for charge ch_test_1',
      metadata: {'stripeRefundId': refundId, 'stripeChargeId': 'ch_test_1', 'refundMethod': 'creditCard'},
    );

/// The charge.refunded webhook's refund row: referenceId the payments doc.
LedgerEntry _webhookRefund(String refundId, double amount, String pi) => _entry(
      'refund_$refundId',
      'refund',
      amount,
      referenceId: 'payment-doc-1',
      description: 'Refund for charge ch_test_1',
      metadata: {'paymentIntentId': pi, 'refundId': refundId, 'chargeId': 'ch_test_1'},
    );

Map<String, dynamic> _row(LedgerEntry entry) => LedgerCardRefund.rowOf(entry);

/// processRefund and the ledger read again, faked. Each call takes the next
/// of [answers]: an answer map, an exception to throw, or a completer whose
/// future it waits on.
class _FakeBackend {
  _FakeBackend(this.answers, {this.ledger = const []});

  final List<Object> answers;
  final calls = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> ledger;
  var rereads = 0;

  Future<Map<String, dynamic>> call(Map<String, dynamic> payload) async {
    calls.add(Map<String, dynamic>.from(payload));
    final answer = answers[calls.length - 1];
    if (answer is Completer<Map<String, dynamic>>) return answer.future;
    if (answer is Exception) throw answer;
    return answer as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> reread() async {
    rereads++;
    return ledger;
  }

  LedgerCardRefundBackend get backend => (call: call, reread: (_, __) => reread());
}

final _requestIdPattern = RegExp(r'^[A-Za-z0-9_-]{8,64}$');

FirebaseFunctionsException _timeout() =>
    FirebaseFunctionsException(code: 'deadline-exceeded', message: 'deadline-exceeded');

/// Words the owner must never be sent to: they refund it themselves.
final _noSupport = isNot(matches(RegExp('support|call us|contact', caseSensitive: false)));

void main() {
  final audits = <AuditLogEntry>[];
  setUp(() {
    audits.clear();
    AuditService.recordForTesting = audits.add;
  });
  tearDown(() => AuditService.recordForTesting = null);

  group('which rows show Refund', () {
    test('only posted card payments not taken for a dispute, with something left to refund', () {
      final rows = LedgerCardRefund.refundableRows([
        _entry('rent', 'rentCharge', 50),
        _card('card', 50, 'pi_test_card'),
        // processRefund's own rows and autopay's name the PaymentIntent in
        // referenceId.
        _entry('card-ref', 'payment', -20, referenceId: 'pi_test_ref'),
        _entry('cash', 'payment', -50, referenceId: 'receipt-17', metadata: {'method': 'cash'}),
        _entry('dispute-pay', 'payment', -30,
            metadata: {'paymentIntentId': 'pi_test_dispute', 'disputeId': 'du_test_1'}),
        _card('voided', 40, 'pi_test_voided', status: LedgerEntryStatus.voided),
        _card('pending', 40, 'pi_test_pending', status: LedgerEntryStatus.pending),
        _card('spent', 25, 'pi_test_spent'),
        _appRefund('re_test_spent', 25, 'pi_test_spent'),
      ]);
      expect(rows.keys, unorderedEquals(['card', 'card-ref']));
      expect(rows['card']!.paymentIntentId, 'pi_test_card');
      expect(rows['card']!.left, 50);
      expect(rows['card-ref']!.paymentIntentId, 'pi_test_ref');
    });

    test('what is left is what was paid less the refunds on the ledger against it, from either writer', () {
      final rows = LedgerCardRefund.refundableRows([
        _card('card', 50, 'pi_test_card'),
        _appRefund('re_test_1', 10, 'pi_test_card'),
        _webhookRefund('re_test_2', 5.5, 'pi_test_card'),
        // Another payment's refund, and an Add entry refund naming none.
        _appRefund('re_test_other', 7, 'pi_test_other'),
        _entry('manual-refund', 'refund', 3),
      ]);
      expect(rows['card']!.paid, 50);
      expect(rows['card']!.left, 34.5);
      expect(rows['card']!.alreadyRefunded, 15.5);
    });

    test('Refund is for owners and managers: the roles processRefund admits hold processRefund', () {
      bool holds(RoleType role, PermissionType p) => PermissionService.getRoleByType(role)!.permissions.contains(p);
      expect(holds(RoleType.owner, PermissionType.processRefund), isTrue);
      expect(holds(RoleType.manager, PermissionType.processRefund), isTrue);
      expect(holds(RoleType.employee, PermissionType.processRefund), isFalse);
      expect(holds(RoleType.viewer, PermissionType.processRefund), isFalse);
      // issueRefund is the owner's alone: gating on it would hide Refund from
      // managers processRefund lets refund.
      expect(holds(RoleType.manager, PermissionType.issueRefund), isFalse);
    });
  });

  group('making the refund through processRefund', () {
    Future<LedgerCardRefundOutcome> run(
      _FakeBackend fake, {
      double amount = 20,
      String requestId = 'lr_test_request_1',
      Set<String> known = const {},
      String? note,
    }) =>
        LedgerCardRefund.refund(
          facilityId: 'fac-1',
          tenantId: 'tenant-1',
          paymentIntentId: 'pi_test_card',
          amount: amount,
          requestId: requestId,
          known: known,
          note: note,
          call: fake.call,
          reread: fake.reread,
        );

    test("sends the move-out's payload, and counts the refund Stripe made", () async {
      final fake = _FakeBackend([
        {'success': true, 'stripeRefundId': 're_test_new'},
      ]);
      final outcome = await run(fake, amount: 20.004, note: '  Unit was never used  ');
      expect(fake.calls.single, {
        'facilityId': 'fac-1',
        'tenantId': 'tenant-1',
        'amount': 20.0,
        'refundMethod': 'creditCard',
        'referenceId': 'pi_test_card',
        'requestId': 'lr_test_request_1',
      });
      expect(outcome.status, LedgerCardRefundStatus.refunded);
      expect(outcome.stripeRefundId, 're_test_new');
      expect(outcome.ownerMessage, isNull);
      expect(fake.rereads, 0);
      // The owner's note has nowhere to go in processRefund: it is kept in
      // the audit log with the outcome.
      final audit = audits.single;
      expect(audit.eventType, 'ledger.cardRefund');
      expect(audit.targetId, 'pi_test_card');
      expect(audit.tenantId, 'tenant-1');
      expect(audit.after, containsPair('note', 'Unit was never used'));
      expect(audit.after, containsPair('stripeRefundId', 're_test_new'));
      expect(audit.after, containsPair('status', 'refunded'));
    });

    test('an uncertain failure whose refund landed on the ledger read again counts as made', () async {
      final fake = _FakeBackend(
        [_timeout()],
        ledger: [
          _row(_card('card', 50, 'pi_test_card')),
          _row(_appRefund('re_test_old', 20, 'pi_test_card')),
          _row(_appRefund('re_test_landed', 20, 'pi_test_card')),
        ],
      );
      final outcome = await run(fake, known: {'re_test_old'});
      expect(fake.rereads, 1);
      expect(outcome.status, LedgerCardRefundStatus.refunded);
      // Not the refund that was there before the dialog opened.
      expect(outcome.stripeRefundId, 're_test_landed');
    });

    test('an uncertain failure that did not land is unconfirmed, never "not refunded"', () async {
      final fake = _FakeBackend(
        [
          FirebaseFunctionsException(
            code: 'internal',
            message: 'Failed to process refund: Card refund failed: socket hang up. No refund was issued.',
          ),
        ],
        ledger: [
          _row(_card('card', 50, 'pi_test_card')),
          // Another amount on this payment, and this amount on another.
          _row(_appRefund('re_test_other_amount', 5, 'pi_test_card')),
          _row(_appRefund('re_test_other_payment', 20, 'pi_test_other')),
        ],
      );
      final outcome = await run(fake);
      expect(fake.rereads, 1);
      expect(outcome.status, LedgerCardRefundStatus.unconfirmed);
      expect(outcome.retryable, isTrue);
      final message = outcome.ownerMessage!;
      expect(message, isNot(contains('Not refunded')));
      expect(message, startsWith('The app could not confirm this refund: Failed to process refund'));
      expect(message, contains('It may still have gone through'));
      expect(message, contains(r'look at this ledger for a new "Refund for charge …" row for $20.00'));
      expect(message, contains('find this payment in your Stripe dashboard'));
      expect(message, _noSupport);
      expect(audits.single.after, containsPair('status', 'unconfirmed'));
    });

    test('a ledger that cannot be read again leaves it unconfirmed', () async {
      final fake = _FakeBackend([_timeout()]);
      final outcome = await LedgerCardRefund.refund(
        facilityId: 'fac-1',
        tenantId: 'tenant-1',
        paymentIntentId: 'pi_test_card',
        amount: 20,
        requestId: 'lr_test_request_1',
        known: const {},
        call: fake.call,
        reread: () async => throw StateError('offline'),
      );
      expect(outcome.status, LedgerCardRefundStatus.unconfirmed);
    });

    test('a refusal before Stripe is not refunded, and the ledger is not read for it', () async {
      for (final code in ['failed-precondition', 'unauthenticated', 'resource-exhausted', 'invalid-argument']) {
        final fake = _FakeBackend(
          [FirebaseFunctionsException(code: code, message: 'App Check token required. Please update your app.')],
          // A refund of this amount someone else made meanwhile is not this one.
          ledger: [_row(_appRefund('re_test_someone_else', 20, 'pi_test_card'))],
        );
        final outcome = await run(fake);
        expect(outcome.status, LedgerCardRefundStatus.notRefunded, reason: code);
        expect(fake.rereads, 0, reason: code);
        expect(outcome.retryable, isTrue);
        final message = outcome.ownerMessage!;
        expect(message, startsWith('Not refunded: App Check token required. Please update your app.'));
        expect(message, contains('Nothing was refunded. Try again in a minute.'));
        expect(message, contains(r'refund $20.00 to their card in your Stripe dashboard'));
        expect(message, _noSupport);
      }
    });

    test('a facility with no connected Stripe account: processRefund only logs it, which is not a refund', () async {
      final fake = _FakeBackend([
        {'success': true, 'refundId': 'refund-1700000000000', 'message': 'Refund logged for processing'},
      ]);
      final outcome = await run(fake);
      expect(outcome.status, LedgerCardRefundStatus.notRefunded);
      expect(outcome.notConnected, isTrue);
      expect(outcome.ownerMessage, contains('Stripe account is not connected'));
      expect(outcome.ownerMessage, _noSupport);
    });

    test('a refund Stripe hands back that was already on the ledger made nothing new', () async {
      final fake = _FakeBackend([
        {'success': true, 'stripeRefundId': 're_test_old'},
      ]);
      final outcome = await run(fake, known: {'re_test_old'});
      expect(outcome.status, LedgerCardRefundStatus.notRefunded);
      expect(outcome.knownRefundId, 're_test_old');
      // Pressing again would hand the same refund back.
      expect(outcome.retryable, isFalse);
      expect(outcome.ownerMessage, startsWith('No new refund was made'));
    });

    test('request ids are new for each dialog and within processRefund\'s limits', () {
      final ids = {for (var i = 0; i < 50; i++) LedgerCardRefund.newRequestId()};
      expect(ids, hasLength(50));
      for (final id in ids) {
        expect(id, matches(_requestIdPattern));
      }
    });
  });

  group('the dialog', () {
    final payment = LedgerCardPayment(paymentIntentId: 'pi_test_card', paid: 50, left: 34.5, paidOn: _sep3);

    Future<List<(double, String, String?)>> pumpDialog(
      WidgetTester tester,
      List<Object> answers, {
      LedgerCardPayment? p,
      double? unconfirmedEarlier,
      void Function(LedgerCardRefundOutcome?)? onClosed,
    }) async {
      final presses = <(double, String, String?)>[];
      var answered = 0;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final outcome = await showDialog<LedgerCardRefundOutcome>(
                context: context,
                barrierDismissible: false,
                builder: (_) => CardRefundDialog(
                  payment: p ?? payment,
                  unconfirmedEarlier: unconfirmedEarlier,
                  onRefund: (amount, requestId, note) async {
                    presses.add((amount, requestId, note));
                    final answer = answers[answered++];
                    if (answer is Completer<LedgerCardRefundOutcome>) return answer.future;
                    return answer as LedgerCardRefundOutcome;
                  },
                ),
              );
              onClosed?.call(outcome);
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return presses;
    }

    Future<void> review(WidgetTester tester, [String? amount]) async {
      if (amount != null) await tester.enterText(find.byKey(const ValueKey('card-refund-amount')), amount);
      await tester.tap(find.byKey(const ValueKey('card-refund-review')));
      await tester.pumpAndSettle();
    }

    Future<void> confirm(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('card-refund-confirm')));
      await tester.pumpAndSettle();
    }

    testWidgets('defaults to what is left after earlier partial refunds, and never takes more', (tester) async {
      await pumpDialog(tester, const []);
      expect(find.text(r'Paid $50.00 by card on Sep 3, 2026.'), findsOneWidget);
      expect(find.text(r'$15.50 of it is already refunded on this ledger.'), findsOneWidget);
      expect(find.text(r'Up to $34.50 can be refunded to their card.'), findsOneWidget);
      final amount = tester.widget<TextField>(find.byKey(const ValueKey('card-refund-amount')));
      expect(amount.controller!.text, '34.50');

      await review(tester, '34.51');
      expect(find.text(r'At most $34.50 is left to refund on this payment.'), findsOneWidget);
      expect(find.byKey(const ValueKey('card-refund-question')), findsNothing);

      await review(tester, '0');
      expect(find.text('Enter the amount to refund.'), findsOneWidget);

      // A partial refund, then the confirm names it.
      await review(tester, '12.25');
      expect(find.text(r'Refund $12.25 to their card?'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, r'Refund $12.25'), findsOneWidget);
    });

    testWidgets('a retry after an uncertain failure resends the same request, at the same amount', (tester) async {
      LedgerCardRefundOutcome? closed;
      final presses = await pumpDialog(
        tester,
        const [
          LedgerCardRefundOutcome.unconfirmed(20, 'deadline-exceeded'),
          LedgerCardRefundOutcome.refunded(20, 're_test_new'),
        ],
        onClosed: (o) => closed = o,
      );
      await tester.enterText(find.byKey(const ValueKey('card-refund-note')), 'Moved out early');
      await review(tester, '20');
      await confirm(tester);

      // Unconfirmed: not "not refunded", and the amount cannot change.
      final message = tester.widget<Text>(find.byKey(const ValueKey('card-refund-message'))).data!;
      expect(message, startsWith('The app could not confirm this refund: deadline-exceeded'));
      expect(message, endsWith(cardRefundRetryNote));
      expect(message, isNot(contains('Not refunded')));
      expect(find.text('Back'), findsNothing);
      expect(find.text('Close'), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Try again'));
      await tester.pumpAndSettle();
      expect(presses, hasLength(2));
      expect(presses[0].$1, 20);
      expect(presses[1].$1, 20);
      expect(presses[0].$2, matches(_requestIdPattern));
      expect(presses[1].$2, presses[0].$2);
      expect(presses[0].$3, 'Moved out early');
      // Refunded: the dialog closes with it.
      expect(find.byType(CardRefundDialog), findsNothing);
      expect(closed?.status, LedgerCardRefundStatus.refunded);
    });

    testWidgets('a new dialog sends a new request id', (tester) async {
      final presses = await pumpDialog(tester, const [
        LedgerCardRefundOutcome.refunded(10, 're_test_a'),
        LedgerCardRefundOutcome.refunded(10, 're_test_b'),
      ]);
      await review(tester, '10');
      await confirm(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await review(tester, '10');
      await confirm(tester);
      expect(presses, hasLength(2));
      expect(presses[1].$2, isNot(presses[0].$2));
    });

    testWidgets('a refusal before Stripe is shown as not refunded, and the amount may be changed', (tester) async {
      final presses = await pumpDialog(tester, const [
        LedgerCardRefundOutcome.notRefunded(20, 'App Check token required. Please update your app.'),
        LedgerCardRefundOutcome.refunded(15, 're_test_new'),
      ]);
      await review(tester, '20');
      await confirm(tester);
      final message = tester.widget<Text>(find.byKey(const ValueKey('card-refund-message'))).data!;
      expect(message, startsWith('Not refunded: App Check token required.'));
      expect(message, isNot(contains(cardRefundRetryNote)));

      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      await review(tester, '15');
      expect(find.byKey(const ValueKey('card-refund-message')), findsNothing);
      await confirm(tester);
      expect(presses.map((p) => p.$1), [20, 15]);
      // Nothing was refunded under the first, so the id stays.
      expect(presses[1].$2, presses[0].$2);
      expect(find.byType(CardRefundDialog), findsNothing);
    });

    testWidgets('a second press while the first is in flight sends nothing', (tester) async {
      final answer = Completer<LedgerCardRefundOutcome>();
      final presses = await pumpDialog(tester, [answer]);
      await review(tester, '20');
      await tester.tap(find.byKey(const ValueKey('card-refund-confirm')));
      await tester.pump();
      expect(find.text('Refunding…'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('card-refund-confirm')), warnIfMissed: false);
      await tester.pump();
      expect(tester.widget<ElevatedButton>(find.byKey(const ValueKey('card-refund-confirm'))).onPressed, isNull);
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Cancel')).onPressed, isNull);
      expect(presses, hasLength(1));
      answer.complete(const LedgerCardRefundOutcome.refunded(20, 're_test_new'));
      await tester.pumpAndSettle();
      expect(find.byType(CardRefundDialog), findsNothing);
    });

    testWidgets('back after an uncertain failure closes with it, so the ledger still says to check', (tester) async {
      LedgerCardRefundOutcome? closed;
      await pumpDialog(
        tester,
        const [LedgerCardRefundOutcome.unconfirmed(20, 'deadline-exceeded')],
        onClosed: (o) => closed = o,
      );
      await review(tester, '20');
      await confirm(tester);
      // The system or browser back, not Close.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(CardRefundDialog), findsNothing);
      expect(closed?.status, LedgerCardRefundStatus.unconfirmed);
    });

    testWidgets('a payment with an unconfirmed refund earlier warns before another', (tester) async {
      await pumpDialog(tester, const [], unconfirmedEarlier: 20);
      expect(find.byKey(const ValueKey('card-refund-unconfirmed-earlier')), findsOneWidget);
    });
  });

  group('on the ledger', () {
    const params = LedgerParams(tenantId: 'tenant-1', facilityId: 'fac-1');

    Future<StreamController<List<LedgerEntry>>> pumpLedger(
      WidgetTester tester,
      List<LedgerEntry> entries, {
      bool allowed = true,
      _FakeBackend? backend,
    }) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final source = StreamController<List<LedgerEntry>>.broadcast();
      addTearDown(source.close);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          ledgerStreamProvider(params).overrideWith((ref) => source.stream),
          facilityTenantsProvider('fac-1').overrideWith((ref) => Stream.value([_tenant])),
          canRefundCardPaymentsAtFacilityProvider('fac-1').overrideWith((ref) async => allowed),
          ledgerCardRefundBackendProvider.overrideWithValue((backend ?? _FakeBackend(const [])).backend),
        ],
        child: MaterialApp(home: Scaffold(body: LedgerScreen(tenant: _tenant))),
      ));
      source.add(entries);
      await tester.pump();
      await tester.pump();
      return source;
    }

    final mixed = [
      _entry('rent', 'rentCharge', 50),
      _card('card', 50, 'pi_test_card'),
      _entry('cash', 'payment', -50, metadata: {'method': 'cash'}),
      _entry('dispute-pay', 'payment', -30, metadata: {'paymentIntentId': 'pi_test_dispute', 'disputeId': 'du_test_1'}),
      _card('voided', 40, 'pi_test_voided', status: LedgerEntryStatus.voided),
    ];

    testWidgets('Refund shows on the card payment only: not cash, a dispute payment or a voided one', (tester) async {
      await pumpLedger(tester, mixed);
      expect(find.text('Refund'), findsOneWidget);
      expect(find.byKey(const ValueKey('ledger-refund-card')), findsOneWidget);
    });

    testWidgets('without the refund permission, no Refund at all', (tester) async {
      await pumpLedger(tester, mixed, allowed: false);
      expect(find.text('Refund'), findsNothing);
    });

    testWidgets('a refund made: the snackbar says so, and the live ledger shows the row and balance', (tester) async {
      final backend = _FakeBackend([
        {'success': true, 'stripeRefundId': 're_test_new'},
      ]);
      final entries = [_entry('rent', 'rentCharge', 50), _card('card', 50, 'pi_test_card')];
      final source = await pumpLedger(tester, entries, backend: backend);
      expect(find.text(r'$0.00'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('ledger-refund-card')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('card-refund-amount')), '20');
      await tester.tap(find.byKey(const ValueKey('card-refund-review')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('card-refund-confirm')));
      await tester.pumpAndSettle();

      expect(backend.calls.single['amount'], 20.0);
      expect(backend.calls.single['referenceId'], 'pi_test_card');
      expect(find.byType(CardRefundDialog), findsNothing);
      expect(find.text(r'Refunded $20.00 to their card'), findsOneWidget);

      // processRefund's row arrives on the stream: no reload.
      source.add([...entries, _appRefund('re_test_new', 20, 'pi_test_card')]);
      await tester.pump();
      await tester.pump();
      // The balance and the refund row.
      expect(find.text(r'$20.00'), findsNWidgets(2));
      expect(find.text('Refund for charge ch_test_1'), findsOneWidget);
      // $30.00 is still left on the payment, so Refund stays.
      expect(find.byKey(const ValueKey('ledger-refund-card')), findsOneWidget);

      // Refunded in full: Refund goes.
      source.add([
        ...entries,
        _appRefund('re_test_new', 20, 'pi_test_card'),
        _webhookRefund('re_test_rest', 30, 'pi_test_card'),
      ]);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('ledger-refund-card')), findsNothing);
    });

    testWidgets('an uncertain failure closed without an answer stays on screen, and the next dialog warns', (tester) async {
      final backend = _FakeBackend([_timeout()]);
      await pumpLedger(tester, [_card('card', 50, 'pi_test_card')], backend: backend);
      await tester.tap(find.byKey(const ValueKey('ledger-refund-card')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('card-refund-review')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('card-refund-confirm')));
      await tester.pumpAndSettle();
      expect(backend.rereads, 1);
      expect(find.text('Close'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Card refund not confirmed'), findsOneWidget);
      expect(find.textContaining('It may still have gone through'), findsOneWidget);
      expect(find.textContaining('Refunded'), findsNothing);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('ledger-refund-card')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('card-refund-unconfirmed-earlier')), findsOneWidget);
    });
  });
}
