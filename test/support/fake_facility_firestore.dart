// The fakes below implement cloud_firestore's @sealed classes so tests can
// run the app's production tenant store (TenantService.recordsFor) and its
// transactions; nothing outside tests sees them.
// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_facility_collection.dart';

/// A Firestore holding one facility's subcollections (units, tenants,
/// gateAccess, ...) as [FakeCollection]s, with transactions: reads come
/// before writes, and the writes land only when the handler returns.
class FakeFacilityFirestore extends Fake implements FirebaseFirestore {
  FakeFacilityFirestore(this.facilityId, Map<String, List<FakeDoc>> docs) {
    for (final e in docs.entries) {
      subcollections[e.key] =
          FakeCollection(e.value, log: FakeQueryLog(), firestore: this);
    }
  }

  final String facilityId;

  /// The facility's subcollections by name; each logs its own writes.
  final Map<String, FakeCollection> subcollections = {};

  /// Transactions that committed.
  var commits = 0;

  FakeCollection sub(String name) => subcollections.putIfAbsent(
      name, () => FakeCollection(<FakeDoc>[], log: FakeQueryLog(), firestore: this));

  /// The stored data of [collection]/[id], or null.
  Map<String, dynamic>? data(String collection, String id) {
    for (final d in sub(collection).stored) {
      if (d.id == id) return d.data();
    }
    return null;
  }

  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) {
    expect(collectionPath, 'facilities');
    return _Facilities(this);
  }

  @override
  Future<T> runTransaction<T>(
    TransactionHandler<T> transactionHandler, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) async {
    final txn = _FakeTransaction();
    final result = await transactionHandler(txn);
    for (final (ref, fields) in txn.writes) {
      await ref.update(fields);
    }
    commits++;
    return result;
  }
}

class _Facilities extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  _Facilities(this._firestore);

  final FakeFacilityFirestore _firestore;

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
    expect(path, _firestore.facilityId);
    return _FacilityDoc(_firestore);
  }
}

class _FacilityDoc extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  _FacilityDoc(this._firestore);

  final FakeFacilityFirestore _firestore;

  @override
  String get id => _firestore.facilityId;

  @override
  FirebaseFirestore get firestore => _firestore;

  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) =>
      _firestore.sub(collectionPath);
}

class _FakeTransaction extends Fake implements Transaction {
  final writes =
      <(DocumentReference<Map<String, dynamic>>, Map<String, dynamic>)>[];

  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(
      DocumentReference<T> documentReference) {
    // Firestore refuses a read after a write in the same transaction.
    if (writes.isNotEmpty) throw StateError('read after write');
    return documentReference.get();
  }

  @override
  Transaction update(
      DocumentReference documentReference, Map<String, dynamic> data) {
    writes.add((
      documentReference as DocumentReference<Map<String, dynamic>>,
      data,
    ));
    return this;
  }
}
