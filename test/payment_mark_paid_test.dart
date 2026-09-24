// The fakes implement cloud_firestore's @sealed document classes so the
// real PaymentService.markPaymentAsPaid can run against them.
// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
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
class _PaymentDoc extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  _PaymentDoc(this.stored);

  final Map<String, dynamic>? stored;
  final List<GetOptions?> reads = [];
  final List<Map<Object, Object?>> updates = [];

  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([
    GetOptions? options,
  ]) async {
    reads.add(options);
    return _StoredPayment(stored);
  }

  @override
  Future<void> update(Map<Object, Object?> data) async => updates.add(data);
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

  setUp(opened.clear);
  tearDown(() => PaymentService.overridePaymentDocForTesting(null));

  Future<void> markPaid() => PaymentService.markPaymentAsPaid(
        facilityId: 'f1',
        paymentId: 'p1',
        method: PaymentMethod.cash,
      );

  // A detail page left open while the payment was paid elsewhere still read
  // pending and offered Process: processing it again moved the tenant's
  // paidThrough on a second month and sent a second receipt.
  test('refuses a payment that is already paid, reading it fresh', () async {
    storeAs({'status': 'paid', 'amount': 100});
    await expectLater(
      markPaid(),
      throwsA(
        isA<PaymentNotProcessableException>().having(
          (e) => e.message,
          'message',
          'This payment has already been paid.',
        ),
      ),
    );
    expect(opened, ['f1/p1']);
    // From the server, not a cached copy as stale as the page's.
    expect(doc.reads.single?.source, Source.server);
    expect(doc.updates, isEmpty);
  });

  test('refuses completed, refunded and cancelled payments too', () async {
    for (final status in ['completed', 'refunded', 'cancelled']) {
      storeAs({'status': status});
      await expectLater(
        markPaid(),
        throwsA(isA<PaymentNotProcessableException>()),
        reason: status,
      );
      expect(doc.updates, isEmpty, reason: status);
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
    expect(doc.updates, isEmpty);
  });

  test('lets a pending or failed payment through the check', () async {
    for (final status in ['pending', 'failed', null]) {
      storeAs({'status': status});
      // It goes on to the signed-in user, which needs Firebase here; the
      // point is that the fresh status did not refuse it.
      await expectLater(
        markPaid(),
        throwsA(isNot(isA<PaymentNotProcessableException>())),
        reason: '$status',
      );
      expect(doc.reads, hasLength(1), reason: '$status');
    }
  });

  // The pages' Process goes through the notifier.
  test('Process on a stale page is refused', () async {
    storeAs({'status': 'paid'});
    final operations = PaymentOperationsNotifier();
    addTearDown(operations.dispose);
    Object? error;
    try {
      await operations.processPayment(
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
      'This payment has already been paid.',
    );
    expect(doc.updates, isEmpty);
  });
}
