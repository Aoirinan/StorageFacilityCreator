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
    testWidgets('cash for a lost dispute, taken from its row, is booked against it and buys no month',
        (tester) async {
      final store = _useStore();
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

      final rows = _ledgerRows(store);
      expect(rows, hasLength(1));
      expect(rows.single['amount'], -100);
      expect(rows.single['type'], 'payment');
      expect(rows.single['description'], 'Card dispute payment - ${PaymentMethod.cash.displayName} #0042');
      expect((rows.single['metadata'] as Map)['disputeId'], 'du_1');
      expect((rows.single['metadata'] as Map)['reference'], '0042');
      // Before: an untagged payment that bought April as well.
      expect(_paidThrough(store), DateTime(2026, 3, 31));
      expect(store.idsIn('facilities/f1/payments'), hasLength(1));

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
