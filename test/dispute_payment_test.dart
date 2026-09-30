import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/providers/ledger_provider.dart';
import 'package:sfcapp/providers/payment_provider.dart';
import 'package:sfcapp/screens/ledger_screen.dart';
import 'package:sfcapp/services/ledger_service.dart';
import 'package:sfcapp/services/payment_service.dart';
import 'package:sfcapp/services/public_payment_link_service.dart';
import 'package:sfcapp/services/stripe_service.dart';
import 'package:sfcapp/widgets/dispute_payment_dialog.dart';

import 'support/fake_firestore_store.dart';

// Made-up names and ids only: this repo is public.

LedgerEntry _entry(
  String id,
  double amount, {
  required String storedType,
  Map<String, dynamic>? metadata,
  LedgerEntryStatus status = LedgerEntryStatus.posted,
}) =>
    LedgerEntry(
      id: id,
      tenantId: 't1',
      facilityId: 'f1',
      type: amount < 0 ? LedgerEntryType.payment : LedgerEntryType.otherCharge,
      amount: amount,
      entryDate: DateTime(2026, 9, 1),
      status: status,
      metadata: metadata,
      createdAt: DateTime(2026, 9, 1),
      createdBy: 'system@stripe-webhook',
      storedType: storedType,
    );

/// March paid by card, then disputed and lost; April rent due.
List<LedgerEntry> _lostDispute() => [
      _entry('march', 100, storedType: 'rentCharge'),
      _entry('payment_pi_march', -100, storedType: 'payment', metadata: {'paymentIntentId': 'pi_march'}),
      _entry('dispute_du_1', 100, storedType: 'dispute', metadata: {'disputeId': 'du_1', 'paymentIntentId': 'pi_march'}),
      _entry('april', 100, storedType: 'rentCharge'),
    ];

/// The row PaymentService.recordManualPayment posts for a dispute payment.
LedgerEntry _handPayment(double amount) => _entry(
      'hand_du_1',
      -amount,
      storedType: 'payment',
      metadata: PaymentService.manualPaymentLedgerMetadata(
        method: PaymentMethod.cash,
        paymentId: 'p_hand',
        disputeId: 'du_1',
      ),
    );

final _tenant = TenantModel(
  id: 't1',
  facilityId: 'f1',
  name: 'Pat Tenant',
  email: '',
  phone: '',
  unitNumber: 'A1',
  monthlyRate: 100,
  createdAt: DateTime(2026, 1, 1),
);

typedef _ManualCall = ({double amount, PaymentMethod method, String? reference, String? disputeId});

/// The ledger's by-hand path ends here: PaymentOperationsNotifier.recordManualPayment.
class _RecordingOperations extends PaymentOperationsNotifier {
  final calls = <_ManualCall>[];

  @override
  Future<void> recordManualPayment({
    required String facilityId,
    required String tenantId,
    required double amount,
    required PaymentMethod method,
    String? notes,
    String? reference,
    String? disputeId,
  }) async {
    calls.add((amount: amount, method: method, reference: reference, disputeId: disputeId));
  }
}

Future<(StreamController<List<LedgerEntry>>, _RecordingOperations)> _pumpLedger(
  WidgetTester tester,
  List<LedgerEntry> entries,
) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  const params = LedgerParams(tenantId: 't1', facilityId: 'f1');
  final source = StreamController<List<LedgerEntry>>.broadcast();
  addTearDown(source.close);
  final operations = _RecordingOperations();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      ledgerStreamProvider(params).overrideWith((ref) => source.stream),
      paymentOperationsProvider.overrideWith((ref) => operations),
    ],
    child: MaterialApp(home: Scaffold(body: LedgerScreen(tenant: _tenant))),
  ));
  source.add(entries);
  await tester.pump();
  await tester.pump();
  return (source, operations);
}

const _action = 'Record payment for this dispute';

/// PaymentService and LedgerService writing to a [FakeStore].
class _StoreFirestore extends Fake implements FirebaseFirestore {
  _StoreFirestore(this.store);

  final FakeStore store;

  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) =>
      store.collection(collectionPath);
}

/// The app's own services on a store holding tenant t1, paid through March.
FakeStore _useStore() {
  final store = FakeStore()
    ..put('facilities/f1/tenants/t1', {
      'name': 'Pat Tenant',
      'unitNumber': 'A1',
      'monthlyRate': 100,
      'paidThrough': Timestamp.fromDate(DateTime(2026, 3, 31)),
    });
  final firestore = _StoreFirestore(store);
  final auth = MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner'));
  PaymentService.firestoreForTesting = firestore;
  PaymentService.authForTesting = auth;
  LedgerService.firestoreForTesting = firestore;
  LedgerService.authForTesting = auth;
  addTearDown(() {
    PaymentService.firestoreForTesting = null;
    PaymentService.authForTesting = null;
    LedgerService.firestoreForTesting = null;
    LedgerService.authForTesting = null;
  });
  return store;
}

List<Map<String, dynamic>> _ledgerRows(FakeStore store) => [
      for (final id in store.idsIn('facilities/f1/ledgers')) store.data('facilities/f1/ledgers/$id')!,
    ];

DateTime? _paidThrough(FakeStore store) =>
    (store.data('facilities/f1/tenants/t1')!['paidThrough'] as Timestamp?)?.toDate();

void main() {
  group("with the app's own payment and ledger services", () {
    testWidgets('cash for a lost dispute, taken from its row, is recorded by the server against it and buys no month',
        (tester) async {
      final store = _useStore();
      final sent = <Map<String, dynamic>>[];
      PaymentService.disputeHandPaymentCallerForTesting = (payload) async {
        sent.add(payload);
        // What recordDisputePaymentByHand writes (functions-shared
        // recordDisputeHandPayment), so the ledger below shows it.
        store.put('facilities/f1/ledgers/disputehand_${payload['requestId']}', {
          'tenantId': 't1',
          'facilityId': 'f1',
          'type': 'payment',
          'amount': -(payload['amount'] as num),
          'description': disputePaymentDescription(PaymentMethod.cash, reference: payload['reference'] as String?),
          'status': 'posted',
          'metadata': {
            'paymentMethod': payload['method'],
            'paymentId': 'disputehand_${payload['requestId']}',
            'reference': payload['reference'],
            'disputeId': payload['disputeId'],
          },
        });
        return {'success': true, 'outcome': 'recorded', 'paymentId': 'disputehand_${payload['requestId']}'};
      };
      addTearDown(() => PaymentService.disputeHandPaymentCallerForTesting = null);
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const params = LedgerParams(tenantId: 't1', facilityId: 'f1');
      final source = StreamController<List<LedgerEntry>>.broadcast();
      addTearDown(source.close);
      // The real PaymentOperationsNotifier: the tap runs all the way to the writes.
      await tester.pumpWidget(ProviderScope(
        overrides: [ledgerStreamProvider(params).overrideWith((ref) => source.stream)],
        child: MaterialApp(home: Scaffold(body: LedgerScreen(tenant: _tenant))),
      ));
      source.add(_lostDispute());
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text(_action));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.descendant(of: find.byType(DisputePaymentDialog), matching: find.byType(TextField)).at(1), '0042');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Record payment'));
      await tester.pumpAndSettle();

      // The server records it, and checks the amount as it writes: the app
      // no longer writes a dispute payment itself.
      expect(sent, hasLength(1));
      expect(sent.single['disputeId'], 'du_1');
      expect(sent.single['amount'], 100);
      expect(sent.single['method'], 'cash');
      expect(sent.single['reference'], '0042');
      expect(sent.single['requestId'], matches(RegExp(r'^[A-Za-z0-9]{24}$')));
      expect(store.idsIn('facilities/f1/payments'), isEmpty);
      expect(store.idsIn('facilities/f1/tenants/t1/payments'), isEmpty);
      final rows = _ledgerRows(store);
      expect(rows, hasLength(1));
      expect(rows.single['amount'], -100);
      expect(rows.single['description'], 'Card dispute payment - ${PaymentMethod.cash.displayName} #0042');
      expect((rows.single['metadata'] as Map)['disputeId'], 'du_1');
      // Before: an untagged payment that bought April as well.
      expect(_paidThrough(store), DateTime(2026, 3, 31));

      // The row the store now holds, back on the ledger: the dispute is
      // settled and April's $100 is what is owed and collectible.
      final entries = [
        ..._lostDispute(),
        _entry('hand_du_1', -100, storedType: 'payment', metadata: Map<String, dynamic>.from(rows.single['metadata'] as Map)),
      ];
      source.add(entries);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('from card disputes'), findsNothing);
      expect(find.text(_action), findsNothing);
      expect(splitPostedLedgerEntries(entries).collectible, 100);
      expect(splitPostedLedgerEntries(entries).disputed, 0);
    });

    test('rent recorded by hand still moves paid-through and carries no dispute id', () async {
      final store = _useStore();

      await PaymentService.recordManualPayment(
        facilityId: 'f1',
        tenantId: 't1',
        amount: 100,
        method: PaymentMethod.check,
        reference: '1234',
      );

      expect((_ledgerRows(store).single['metadata'] as Map).containsKey('disputeId'), isFalse);
      expect(_paidThrough(store), DateTime(2026, 4, 30));
    });
  });

  testWidgets(
      'a lost dispute paid in cash from its ledger row is booked against the dispute, and the note goes',
      (tester) async {
    final (source, operations) = await _pumpLedger(tester, _lostDispute());

    expect(find.text(disputedBalanceNote(100)), findsOneWidget);
    // Only the dispute's own row offers it.
    expect(find.text(_action), findsOneWidget);

    await tester.tap(find.text(_action));
    await tester.pumpAndSettle();
    expect(find.byType(DisputePaymentDialog), findsOneWidget);
    // Cash by default, for what the dispute has out.
    await tester.enterText(
        find.descendant(of: find.byType(DisputePaymentDialog), matching: find.byType(TextField)).at(1), '0042');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Record payment'));
    await tester.pumpAndSettle();

    // Before: recorded as an ordinary payment, with no dispute id.
    expect(operations.calls, [
      (amount: 100.0, method: PaymentMethod.cash, reference: '0042', disputeId: 'du_1'),
    ]);

    source.add([..._lostDispute(), _handPayment(100)]);
    await tester.pump();
    await tester.pump();

    // The dispute is paid: nothing left to point staff at, and April is
    // still the $100 owed.
    expect(find.textContaining('from card disputes'), findsNothing);
    expect(find.text(_action), findsNothing);
    expect(splitPostedLedgerEntries([..._lostDispute(), _handPayment(100)]).collectible, 100);
  });

  testWidgets('the note is left out when the balance is \$0.00, even with a dispute out', (tester) async {
    // The dispute's $100 is covered by an untagged $100 credit elsewhere.
    await _pumpLedger(tester, [
      _entry('dispute_du_1', 100, storedType: 'dispute', metadata: {'disputeId': 'du_1'}),
      _entry('credit', -100, storedType: 'payment'),
    ]);

    // Before: 'Includes $100.00 from card disputes' on a $0.00 balance.
    expect(find.textContaining('from card disputes'), findsNothing);
  });

  testWidgets('the note names only the part of the balance that is disputed', (tester) async {
    await _pumpLedger(tester, [
      _entry('dispute_du_1', 100, storedType: 'dispute', metadata: {'disputeId': 'du_1'}),
      _entry('credit', -60, storedType: 'payment'),
    ]);

    expect(find.text(disputedBalanceNote(40)), findsOneWidget);
  });

  testWidgets('the dialog refuses more than the dispute has out', (tester) async {
    final (_, operations) = await _pumpLedger(tester, [..._lostDispute(), _handPayment(40)]);

    await tester.tap(find.text(_action));
    await tester.pumpAndSettle();
    // $40 already taken for it: $60 is prefilled, and $60.01 is refused.
    expect(find.text('60.00'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('dispute-payment-amount')), '60.01');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Record payment'));
    await tester.pumpAndSettle();

    expect(find.text('This dispute has \$60.00 left to collect.'), findsOneWidget);
    expect(operations.calls, isEmpty);
  });

  test('which rows offer a dispute payment', () {
    final open = _lostDispute();
    expect(openDisputeOutstanding(open[2], open), 100);
    // Not the payment or the rent.
    expect(openDisputeOutstanding(open[1], open), isNull);
    expect(openDisputeOutstanding(open[3], open), isNull);
    // Paid by hand, won (reversal and settled marker), or voided: nothing left.
    expect(openDisputeOutstanding(open[2], [...open, _handPayment(100)]), isNull);
    final won = _entry('dispute_du_1', 100, storedType: 'dispute', metadata: {
      'disputeId': 'du_1',
      'settledByEntryId': 'dispute_du_1_reinstated',
    });
    expect(openDisputeOutstanding(won, [won]), isNull);
    final voided = _entry('dispute_du_1', 100,
        storedType: 'dispute', metadata: {'disputeId': 'du_1'}, status: LedgerEntryStatus.voided);
    expect(openDisputeOutstanding(voided, [voided]), isNull);
    // Put on an invoice (before dispute rows were kept off them) and that
    // invoice paid: the payment is not tagged, but the dispute is settled.
    final invoiced = _entry('dispute_du_1', 100, storedType: 'dispute', metadata: {
      'disputeId': 'du_1',
      'allocatedAmount': 100,
      'settledByInvoiceId': 'inv_1',
    });
    expect(openDisputeOutstanding(invoiced, [invoiced]), isNull);
  });

  test('a dispute paid by hand and then won is a credit against rent, not a disputed amount', () {
    final entries = [
      ..._lostDispute(),
      _handPayment(100),
      _entry('dispute_du_1_reinstated', -100, storedType: 'dispute_reversal', metadata: {'disputeId': 'du_1'}),
    ];
    // March paid twice, April owed once: nothing for autopay to charge.
    // Before: {total 0, disputed -100, collectible 100}.
    final split = splitPostedLedgerEntries(entries);
    expect(split.total, 0);
    expect(split.disputed, 0);
    expect(split.collectible, 0);
    expect(openDisputeOutstanding(entries[2], entries), isNull);
  });

  group('the dialog and the card on file', () {
    Future<List<DisputePaymentEntry?>> open(WidgetTester tester, {String? reason}) async {
      final results = <DisputePaymentEntry?>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => results.add(await showDialog<DisputePaymentEntry>(
                context: context,
                builder: (_) => DisputePaymentDialog(outstanding: 100, hasCardOnFile: true, disputeReason: reason),
              )),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return results;
    }

    testWidgets('a fraud dispute does not offer the card on file, and says why', (tester) async {
      await open(tester, reason: fraudulentDisputeReason);

      expect(find.text(fraudDisputeCardNote), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('dispute-payment-method')));
      await tester.pumpAndSettle();
      // Before: offered, and the charge went back on a card whose holder
      // told their bank the first charge was not theirs.
      expect(find.text('Charge card on file'), findsNothing);
      expect(find.text('Send a payment link'), findsWidgets);
    });

    testWidgets('any other dispute asks staff to confirm the tenant agreed before the card is charged',
        (tester) async {
      final results = await open(tester, reason: 'product_not_received');

      expect(find.text(fraudDisputeCardNote), findsNothing);
      await tester.tap(find.byKey(const ValueKey('dispute-payment-method')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Charge card on file').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Charge card'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm the tenant agreed to this card charge.'), findsOneWidget);
      expect(results, isEmpty);

      await tester.tap(find.text(cardConsentLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Charge card'));
      await tester.pumpAndSettle();
      expect(results.single?.way, DisputePaymentWay.cardOnFile);
      expect(results.single?.amount, 100);
      // The confirmation goes to the server, which refuses the charge without it.
      expect(results.single?.tenantConsent, isTrue);
    });

    testWidgets('money taken by hand carries no card consent', (tester) async {
      final results = await open(tester, reason: 'product_not_received');

      await tester.tap(find.widgetWithText(ElevatedButton, 'Record payment'));
      await tester.pumpAndSettle();

      expect(results.single?.way, DisputePaymentWay.byHand);
      expect(results.single?.tenantConsent, isFalse);
    });
  });

  test('a dispute payment by hand goes to the server with a request id, and the app writes nothing', () async {
    final store = _useStore();
    final sent = <Map<String, dynamic>>[];
    PaymentService.disputeHandPaymentCallerForTesting = (payload) async {
      sent.add(payload);
      return {'success': true, 'outcome': 'recorded', 'paymentId': 'disputehand_x'};
    };
    addTearDown(() => PaymentService.disputeHandPaymentCallerForTesting = null);

    final id = await PaymentService.recordManualPayment(
      facilityId: 'f1',
      tenantId: 't1',
      amount: 60,
      method: PaymentMethod.zelle,
      reference: ' zr-9 ',
      notes: ' paid by phone ',
      disputeId: ' du_1 ',
    );

    expect(id, 'disputehand_x');
    expect(sent.single, {
      'facilityId': 'f1',
      'tenantId': 't1',
      'disputeId': 'du_1',
      'amount': 60.0,
      'method': 'zelle',
      'requestId': sent.single['requestId'],
      'reference': 'zr-9',
      'notes': 'paid by phone',
    });
    expect(sent.single['requestId'], matches(RegExp(r'^[A-Za-z0-9]{24}$')));
    expect(_ledgerRows(store), isEmpty);
    expect(store.idsIn('facilities/f1/payments'), isEmpty);
    // A refusal (more than the dispute has out) reaches the caller.
    PaymentService.disputeHandPaymentCallerForTesting = (_) async => throw Exception('That card dispute has \$40.00 left to collect.');
    await expectLater(
      PaymentService.recordManualPayment(
        facilityId: 'f1',
        tenantId: 't1',
        amount: 60,
        method: PaymentMethod.cash,
        disputeId: 'du_1',
      ),
      throwsA(isA<Exception>()),
    );
    expect(_ledgerRows(store), isEmpty);
  });

  test('a dispute payment by hand is tagged with the dispute and reads as a dispute row', () {
    final metadata = PaymentService.manualPaymentLedgerMetadata(
      method: PaymentMethod.check,
      paymentId: 'p1',
      reference: '1234',
      disputeId: 'du_1',
    );
    expect(metadata, {'paymentMethod': 'check', 'paymentId': 'p1', 'reference': '1234', 'disputeId': 'du_1'});
    expect(isDisputeLedgerRow({'type': 'payment', 'metadata': metadata}), isTrue);
    // An ordinary payment is still rent.
    final rent = PaymentService.manualPaymentLedgerMetadata(method: PaymentMethod.cash, paymentId: 'p2');
    expect(rent.containsKey('disputeId'), isFalse);
    expect(isDisputeLedgerRow({'type': 'payment', 'metadata': rent}), isFalse);
    expect(disputePaymentDescription(PaymentMethod.check, reference: '1234'),
        'Card dispute payment - ${PaymentMethod.check.displayName} #1234');
  });

  test('a dispute payment by hand does not move paid-through; rent at the counter still does', () {
    // Before: the $100 for a lost March dispute bought April, so April read
    // as paid and the delinquency job skipped it.
    expect(PaymentService.manualPaymentBuysRent(appliesToRent: true, disputeId: 'du_1'), isFalse);
    expect(PaymentService.manualPaymentBuysRent(appliesToRent: true), isTrue);
    expect(PaymentService.manualPaymentBuysRent(appliesToRent: true, disputeId: '  '), isTrue);
    expect(PaymentService.manualPaymentBuysRent(appliesToRent: false), isFalse);
  });

  test('the card-on-file charge and the payment link send the dispute id to the server', () {
    final charge = StripeService.chargeTenantOffSessionPayload(
      facilityId: 'f1',
      tenantId: 't1',
      paymentMethodId: 'pm_1',
      amount: 100,
      disputeId: 'du_1',
    );
    expect(charge['disputeId'], 'du_1');
    // No consent confirmed: none sent, and the server refuses the charge.
    expect(charge.containsKey('tenantConsent'), isFalse);
    expect(
      StripeService.chargeTenantOffSessionPayload(
        facilityId: 'f1',
        tenantId: 't1',
        paymentMethodId: 'pm_1',
        amount: 100,
        disputeId: 'du_1',
        tenantConsent: true,
      )['tenantConsent'],
      isTrue,
    );
    final link = PublicPaymentLinkService.createPaymentLinkPayload(
      facilityId: 'f1',
      tenantId: 't1',
      amount: 100,
      expiresAt: DateTime.utc(2026, 10, 28),
      disputeId: 'du_1',
    );
    expect(link['disputeId'], 'du_1');
    // Ordinary charges and links carry none.
    expect(
      StripeService.chargeTenantOffSessionPayload(facilityId: 'f1', tenantId: 't1', paymentMethodId: 'pm_1', amount: 5)
          .containsKey('disputeId'),
      isFalse,
    );
    expect(
      PublicPaymentLinkService.createPaymentLinkPayload(
        facilityId: 'f1',
        tenantId: 't1',
        amount: 5,
        expiresAt: DateTime.utc(2026, 10, 28),
      ).containsKey('disputeId'),
      isFalse,
    );
  });
}
