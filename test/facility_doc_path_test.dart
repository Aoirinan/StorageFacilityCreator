// The fakes implement cloud_firestore's @sealed reference and snapshot
// classes so the models' real fromFirestore can read a doc's path.
// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/contract_model.dart';
import 'package:sfcapp/models/payment_model.dart';

class _Collection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  _Collection(this.id, this.parent);

  @override
  final String id;

  @override
  final DocumentReference<Map<String, dynamic>>? parent;
}

class _Doc extends Fake implements DocumentReference<Map<String, dynamic>> {
  _Doc(this.id, this.parent);

  @override
  final String id;

  @override
  final CollectionReference<Map<String, dynamic>> parent;
}

class _Snapshot extends Fake
    implements DocumentSnapshot<Map<String, dynamic>> {
  _Snapshot(this.reference, this._data);

  @override
  final DocumentReference<Map<String, dynamic>> reference;
  final Map<String, dynamic> _data;

  @override
  String get id => reference.id;

  @override
  bool get exists => true;

  @override
  Map<String, dynamic> data() => _data;
}

/// The doc at [path], e.g. 'facilities/f1/payments/p1', holding [data].
_Snapshot _docAt(String path, Map<String, dynamic> data) {
  final segments = path.split('/');
  DocumentReference<Map<String, dynamic>>? doc;
  for (var i = 0; i < segments.length; i += 2) {
    doc = _Doc(segments[i + 1], _Collection(segments[i], doc));
  }
  return _Snapshot(doc!, data);
}

final _created = Timestamp.fromDate(DateTime(2026, 9, 1));

Map<String, dynamic> _payment({String? facilityId}) => {
      if (facilityId != null) 'facilityId': facilityId,
      'tenantId': 't1',
      'amount': 100,
      'status': 'pending',
      'createdAt': _created,
    };

Map<String, dynamic> _contract({String? facilityId}) => {
      if (facilityId != null) 'facilityId': facilityId,
      'tenantId': 't1',
      'title': 'Lease',
      'createdAt': _created,
    };

// A doc written without a facilityId read back with ''. The pages act
// through model.facilityId, so Process on such a payment, or a contract's
// actions, went to facilities//... and failed. Only pages opened by a link
// were covered (from the link's facility); the lists were not.
void main() {
  group('PaymentModel.fromFirestore', () {
    test('takes the facility from the path when the field is missing', () {
      final payment = PaymentModel.fromFirestore(
        _docAt('facilities/f1/payments/p1', _payment()),
      );
      expect(payment.facilityId, 'f1');
      expect(payment.id, 'p1');
    });

    test('and when it is empty', () {
      final payment = PaymentModel.fromFirestore(
        _docAt('facilities/f1/payments/p1', _payment(facilityId: '')),
      );
      expect(payment.facilityId, 'f1');
    });

    test('keeps the stored facility', () {
      final payment = PaymentModel.fromFirestore(
        _docAt('facilities/f1/payments/p1', _payment(facilityId: 'f9')),
      );
      expect(payment.facilityId, 'f9');
    });

    // recordManualPayment also writes a copy under the tenant. Its parent's
    // parent is the tenant, not a facility.
    test('is not a tenant id for a copy stored under the tenant', () {
      final payment = PaymentModel.fromFirestore(
        _docAt('facilities/f1/tenants/t1/payments/p1', _payment()),
      );
      expect(payment.facilityId, '');
    });
  });

  group('ContractModel.fromFirestore', () {
    test('takes the facility from the path when the field is missing', () {
      final contract = ContractModel.fromFirestore(
        _docAt('facilities/f1/contracts/c1', _contract()),
      );
      expect(contract.facilityId, 'f1');
      expect(contract.id, 'c1');
    });

    test('keeps the stored facility', () {
      final contract = ContractModel.fromFirestore(
        _docAt('facilities/f1/contracts/c1', _contract(facilityId: 'f9')),
      );
      expect(contract.facilityId, 'f9');
    });

    test('is empty for a contract stored outside a facility', () {
      final contract = ContractModel.fromFirestore(
        _docAt('contracts/c1', _contract()),
      );
      expect(contract.facilityId, '');
    });
  });
}
