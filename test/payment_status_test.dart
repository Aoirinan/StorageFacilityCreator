// The fake implements cloud_firestore's @sealed snapshot class so the
// model's real fromFirestore can read it.
// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/models/tenant_portal_models.dart';
import 'package:sfcapp/services/payment_service.dart';

class _Snapshot extends Fake
    implements DocumentSnapshot<Map<String, dynamic>> {
  _Snapshot(this._data);

  final Map<String, dynamic> _data;

  @override
  String get id => 'p1';

  @override
  bool get exists => true;

  @override
  Map<String, dynamic> data() => _data;
}

PaymentModel _stored(Object? status) => PaymentModel.fromFirestore(_Snapshot({
      'facilityId': 'f1',
      'tenantId': 't1',
      'amount': 100,
      'status': status,
      'dueDate': Timestamp.fromDate(DateTime(2026, 9, 1)),
    }));

void main() {
  // The Stripe webhooks write disputed (stripeWebhookDisputeCreated) and
  // partially_refunded (stripeWebhookChargeRefunded). Both read as pending,
  // so the list and detail pages offered Process on them.
  test('a disputed or part-refunded payment reads as what it is', () {
    final disputed = _stored('disputed');
    expect(disputed.status, PaymentStatus.disputed);
    expect(disputed.statusDisplayName, 'Disputed');
    expect(disputed.isOverdue, isFalse);

    final partRefunded = _stored('partially_refunded');
    expect(partRefunded.status, PaymentStatus.partiallyRefunded);
    expect(partRefunded.statusDisplayName, 'Partially refunded');
  });

  test('a status this app has no name for is shown as stored, not pending',
      () {
    final odd = _stored('requires_action');
    expect(odd.status, PaymentStatus.other);
    expect(odd.statusDisplayName, 'Requires action');
    // An edit writes it back unchanged rather than as a guess.
    expect(odd.toFirestore()['status'], 'requires_action');
  });

  test('only a missing status still reads as pending', () {
    expect(_stored(null).status, PaymentStatus.pending);
    expect(_stored('pending').status, PaymentStatus.pending);
    expect(_stored('paid').status, PaymentStatus.paid);
  });

  test('part-refunded is written back as the webhooks write it', () {
    expect(
      _stored('partially_refunded').toFirestore()['status'],
      'partially_refunded',
    );
    expect(PaymentStatus.partiallyRefunded.storedValue, 'partially_refunded');
    expect(PaymentStatus.disputed.storedValue, 'disputed');
  });

  // The tenant portal lists the facility's payment docs too, and showed a
  // payment the tenant had disputed as still pending.
  test('the tenant portal shows a disputed payment as disputed', () {
    PaymentStatus portal(String status) =>
        PortalPaymentSummary.fromMap({'id': 'p1', 'amount': 1, 'status': status})
            .status;
    expect(portal('disputed'), PaymentStatus.disputed);
    expect(portal('partially_refunded'), PaymentStatus.partiallyRefunded);
    expect(portal('requires_action'), PaymentStatus.other);
    expect(
      PortalPaymentSummary.fromMap({'id': 'p2', 'amount': 1}).status,
      PaymentStatus.pending,
    );
  });

  // Process is refused by an allowlist, so a status added later is refused
  // until someone decides it may be processed.
  test('Process is allowed only for a payment still owed', () {
    for (final status in [null, 'pending', 'failed']) {
      expect(paymentNotProcessableReason(status), isNull, reason: '$status');
    }
    for (final status in [
      'paid',
      'completed',
      'succeeded',
      'refunded',
      'partially_refunded',
      'cancelled',
      'disputed',
      'something_new',
    ]) {
      expect(
        paymentNotProcessableReason(status),
        endsWith(', so it cannot be processed.'),
        reason: status,
      );
    }
  });
}
