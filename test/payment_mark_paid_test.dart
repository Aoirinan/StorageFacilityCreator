// The fakes implement cloud_firestore's @sealed document, transaction and
// Firestore classes so the real PaymentService.markPaymentAsPaid can run
// against them.
// ignore_for_file: subtype_of_sealed_class, must_be_immutable

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/providers/payment_provider.dart';
import 'package:sfcapp/services/payment_service.dart';
import 'package:sfcapp/utils/error_message_helper.dart';

class _StoredPayment extends Fake
    implements DocumentSnapshot<Map<String, dynamic>> {
  _StoredPayment(this._data);

  final Map<String, dynamic>? _data;

  @override
  bool get exists => _data != null;

  @override
  Map<String, dynamic>? data() => _data;
}

/// The payment doc as stored now, whatever the page that opened it shows.
/// Versioned the way Firestore versions a doc, so a transaction that read
/// an older version cannot commit.
class _PaymentDoc extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  _PaymentDoc(this.stored) {
    firestore = _FakeFirestore(this);
  }

  Map<String, dynamic>? stored;
  int version = 0;

  /// Committed writes, in order.
  final List<Map<String, dynamic>> commits = [];

  @override
  late final _FakeFirestore firestore;
}

class _FakeTransaction extends Fake implements Transaction {
  _FakeTransaction(this.doc, this.onRead);

  final _PaymentDoc doc;
  final Future<void> Function() onRead;
  int? readVersion;
  final List<Map<String, dynamic>> writes = [];

  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(
    DocumentReference<T> documentReference,
  ) async {
    expect(documentReference, same(doc));
    readVersion = doc.version;
    final data = doc.stored == null ? null : Map.of(doc.stored!);
    await onRead();
    return _StoredPayment(data) as DocumentSnapshot<T>;
  }

  @override
  Transaction update(
    DocumentReference documentReference,
    Map<String, dynamic> data,
  ) {
    expect(documentReference, same(doc));
    writes.add(data);
    return this;
  }
}

/// Runs transactions as Firestore does: a transaction whose doc changed
/// after it read it is run again from the start.
class _FakeFirestore extends Fake implements FirebaseFirestore {
  _FakeFirestore(this.payment);

  final _PaymentDoc payment;
  int attempts = 0;

  /// Awaited after each transactional read; lets a test hold two
  /// transactions until both have read.
  Future<void> Function() onRead = () async {};

  @override
  Future<T> runTransaction<T>(
    TransactionHandler<T> transactionHandler, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) async {
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      attempts++;
      final txn = _FakeTransaction(payment, onRead);
      final result = await transactionHandler(txn);
      if (txn.readVersion != null && txn.readVersion != payment.version) {
        continue;
      }
      for (final write in txn.writes) {
        payment.stored = {...?payment.stored, ...write};
        payment.version++;
        payment.commits.add(write);
      }
      return result;
    }
    throw FirebaseException(plugin: 'cloud_firestore', code: 'aborted');
  }
}

void main() {
  late _PaymentDoc doc;
  final opened = <String>[];

  void storeAs(Map<String, dynamic>? stored) {
    doc = _PaymentDoc(stored);
    PaymentService.overridePaymentDocForTesting((facilityId, paymentId) {
      opened.add('$facilityId/$paymentId');
      return doc;
    });
  }

  setUp(() {
    opened.clear();
    PaymentService.authForTesting =
        MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner-1'));
  });
  tearDown(() {
    PaymentService.overridePaymentDocForTesting(null);
    PaymentService.authForTesting = null;
  });

  Future<void> markPaid() => PaymentService.markPaymentAsPaid(
        facilityId: 'f1',
        paymentId: 'p1',
        method: PaymentMethod.cash,
      );

  Matcher refusedWith(String message) => throwsA(
        isA<PaymentNotProcessableException>()
            .having((e) => e.message, 'message', message),
      );

  // A detail page left open while the payment was paid elsewhere still read
  // pending and offered Process: processing it again moved the tenant's
  // paidThrough on a second month and sent a second receipt.
  test('refuses a payment that is already paid, reading it in a transaction',
      () async {
    storeAs({'status': 'paid', 'amount': 100});
    await expectLater(
      markPaid(),
      refusedWith('This payment is already paid, so it cannot be processed.'),
    );
    expect(opened, ['f1/p1']);
    expect(doc.firestore.attempts, 1);
    expect(doc.commits, isEmpty);
  });

  // The Stripe webhooks write disputed and partially_refunded to these docs.
  // The refusal was a denylist that did not name them: Process overwrote the
  // dispute with paid and moved paidThrough on a free month.
  test('refuses every status but pending and failed', () async {
    const refused = {
      'disputed': 'This payment is disputed, so it cannot be processed.',
      'partially_refunded':
          'This payment is partially refunded, so it cannot be processed.',
      'succeeded': 'This payment is already paid, so it cannot be processed.',
      'completed': 'This payment is already paid, so it cannot be processed.',
      'refunded': 'This payment is refunded, so it cannot be processed.',
      'cancelled': 'This payment is cancelled, so it cannot be processed.',
      'processing':
          'This payment is marked "processing", so it cannot be processed.',
    };
    for (final MapEntry(key: status, value: message) in refused.entries) {
      storeAs({'status': status});
      await expectLater(markPaid(), refusedWith(message), reason: status);
      expect(doc.commits, isEmpty, reason: status);
      expect(doc.stored?['status'], status, reason: status);
    }
  });

  test('refuses a payment that is gone', () async {
    storeAs(null);
    await expectLater(
      markPaid(),
      throwsA(
        predicate((e) => e.toString().contains('Payment not found')),
      ),
    );
    expect(doc.commits, isEmpty);
  });

  test('marks a pending, failed or status-less payment paid', () async {
    for (final status in ['pending', 'failed', null]) {
      storeAs({'status': status, 'amount': 100});
      // The tenant and receipt steps after it need Firebase and swallow
      // their own failures; the payment write is what is checked here.
      await markPaid();
      expect(doc.commits, hasLength(1), reason: '$status');
      expect(doc.commits.single['status'], 'paid', reason: '$status');
      expect(doc.commits.single['paidBy'], 'owner-1', reason: '$status');
    }
  });

  // Two Process clicks on two pages each read pending before either wrote,
  // and both went through: two months of paidThrough and two receipts.
  test('two Process at once: one marks it paid, the other is refused',
      () async {
    storeAs({'status': 'pending', 'amount': 100});
    final bothRead = Completer<void>();
    var reads = 0;
    doc.firestore.onRead = () async {
      reads++;
      if (reads == 2) bothRead.complete();
      if (reads <= 2) await bothRead.future;
    };

    final outcomes = await Future.wait([
      for (var i = 0; i < 2; i++)
        markPaid().then<Object?>((_) => 'paid', onError: (Object e) => e),
    ]);

    expect(doc.commits, hasLength(1));
    expect(outcomes.where((o) => o == 'paid'), hasLength(1));
    final refused = outcomes.whereType<PaymentNotProcessableException>();
    expect(refused, hasLength(1));
    expect(
      refused.single.message,
      'This payment is already paid, so it cannot be processed.',
    );
    // The loser read again after the winner committed.
    expect(doc.firestore.attempts, 3);
  });

  // The pages' Process goes through the notifier.
  test('Process on a stale page is refused and its lists are reloaded',
      () async {
    storeAs({'status': 'disputed'});
    var listBuilds = 0;
    var statsBuilds = 0;
    final container = ProviderContainer(
      overrides: [
        paymentListProvider('f1').overrideWith((ref) {
          listBuilds++;
          return Stream.value(const <PaymentModel>[]);
        }),
        paymentStatsProvider('f1').overrideWith((ref) async {
          statsBuilds++;
          return const <String, dynamic>{};
        }),
      ],
    );
    addTearDown(container.dispose);
    container.listen(paymentListProvider('f1'), (_, __) {});
    container.listen(paymentStatsProvider('f1'), (_, __) {});
    await container.read(paymentStatsProvider('f1').future);
    expect((listBuilds, statsBuilds), (1, 1));

    Object? error;
    try {
      await container.read(paymentOperationsProvider.notifier).processPayment(
            facilityId: 'f1',
            paymentId: 'p1',
            method: PaymentMethod.cash,
          );
    } catch (e) {
      error = e;
    }
    expect(error, isA<PaymentNotProcessableException>());
    // The pages show it as it is, not "An error occurred".
    expect(
      ErrorMessageHelper.getUserFriendlyMessage(error),
      'This payment is disputed, so it cannot be processed.',
    );
    expect(doc.commits, isEmpty);

    // The row that offered Process was stale; the list and stats reload.
    container.read(paymentListProvider('f1'));
    await container.read(paymentStatsProvider('f1').future);
    expect((listBuilds, statsBuilds), (2, 2));
  });

  test('a Process that fails for another reason does not reload the lists',
      () async {
    var listBuilds = 0;
    final operations = PaymentOperationsNotifier(onRefused: (_) => listBuilds++);
    addTearDown(operations.dispose);
    PaymentService.authForTesting = MockFirebaseAuth();
    await expectLater(
      operations.processPayment(
        facilityId: 'f1',
        paymentId: 'p1',
        method: PaymentMethod.cash,
      ),
      throwsA(isNot(isA<PaymentNotProcessableException>())),
    );
    expect(listBuilds, 0);
  });
}
