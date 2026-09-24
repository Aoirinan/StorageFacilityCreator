// The fakes below implement cloud_firestore's @sealed query and snapshot
// classes so tests can run the app's real tenant and unit reads (through
// FacilitySubcollections.overrideForTesting); nothing outside tests sees them.
// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

/// One stored doc. Its data is copied, so writes through
/// [FakeCollection.doc] change this doc and never the caller's map.
class FakeDoc extends Fake
    implements QueryDocumentSnapshot<Map<String, dynamic>> {
  FakeDoc(this.id, Map<String, dynamic> data)
      : _data = Map<String, dynamic>.of(data);

  @override
  final String id;
  final Map<String, dynamic> _data;

  @override
  Map<String, dynamic> data() => _data;

  @override
  bool get exists => true;
}

/// What the code under test asked of a [FakeCollection] and the queries
/// built from it.
class FakeQueryLog {
  final List<int> limits = [];
  final List<Object> orderedBy = [];
  final List<(Object field, Object? isEqualTo)> equalityFilters = [];

  /// Writes through [FakeCollection.doc], in order: ('set' or 'update',
  /// doc id, data as sent).
  final List<(String op, String id, Map<String, dynamic> data)> writes = [];
}

/// A facility subcollection that answers queries the way Firestore does for
/// the operations the app's reads use: equality `where`, `orderBy` (which
/// leaves out docs without the field), `limit`, `get`, `snapshots` and
/// `count`, plus `doc(id)` with `get`, `set` and `update` for the app's unit
/// writes. Anything else fails the test.
class FakeCollection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  FakeCollection(List<FakeDoc> docs, {FakeQueryLog? log})
      : this._(docs, log ?? FakeQueryLog(), null);

  FakeCollection._(this._docs, this.log, this._limit);

  final List<FakeDoc> _docs;
  final FakeQueryLog log;
  final int? _limit;

  List<FakeDoc> get _served {
    final limit = _limit;
    return limit == null ? _docs : _docs.take(limit).toList();
  }

  @override
  Query<Map<String, dynamic>> where(
    Object field, {
    Object? isEqualTo,
    Object? isNotEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    Object? arrayContains,
    Iterable<Object?>? arrayContainsAny,
    Iterable<Object?>? whereIn,
    Iterable<Object?>? whereNotIn,
    bool? isNull,
  }) {
    if (isEqualTo == null ||
        isNotEqualTo != null ||
        isLessThan != null ||
        isLessThanOrEqualTo != null ||
        isGreaterThan != null ||
        isGreaterThanOrEqualTo != null ||
        arrayContains != null ||
        arrayContainsAny != null ||
        whereIn != null ||
        whereNotIn != null ||
        isNull != null) {
      throw UnimplementedError('FakeCollection only supports isEqualTo');
    }
    log.equalityFilters.add((field, isEqualTo));
    // Firestore equality: the field must exist and hold exactly this value.
    return FakeCollection._(
      [
        for (final d in _docs)
          if (d.data().containsKey(field) && d.data()[field] == isEqualTo) d,
      ],
      log,
      _limit,
    );
  }

  @override
  Query<Map<String, dynamic>> orderBy(Object field, {bool descending = false}) {
    log.orderedBy.add(field);
    // Firestore leaves docs without the field out of an ordered query.
    final kept = [
      for (final d in _docs)
        if (d.data()[field] != null) d,
    ]..sort((a, b) {
        final byField =
            (a.data()[field] as Comparable).compareTo(b.data()[field]);
        return descending ? -byField : byField;
      });
    return FakeCollection._(kept, log, _limit);
  }

  @override
  Query<Map<String, dynamic>> limit(int limit) {
    log.limits.add(limit);
    return FakeCollection._(_docs, log, limit);
  }

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) async =>
      _FakeSnapshot(_served);

  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) =>
      Stream.value(_FakeSnapshot(_served));

  @override
  AggregateQuery count() => _FakeCountQuery(_served.length);

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      _FakeDocRef(this, path ?? 'auto-${_docs.length + log.writes.length}');
}

class _FakeDocRef extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  _FakeDocRef(this._collection, this.id);

  final FakeCollection _collection;

  @override
  final String id;

  FakeDoc? get _stored {
    for (final d in _collection._docs) {
      if (d.id == id) return d;
    }
    return null;
  }

  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([GetOptions? options]) async {
    final stored = _stored;
    if (stored != null) return stored;
    return _MissingDoc(id);
  }

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    _collection.log.writes.add(('set', id, data));
    _collection._docs
      ..removeWhere((d) => d.id == id)
      ..add(FakeDoc(id, data));
  }

  @override
  Future<void> update(Map<Object, Object?> data) async {
    final stored = _stored;
    if (stored == null) {
      throw FirebaseException(plugin: 'cloud_firestore', code: 'not-found');
    }
    final fields = {for (final e in data.entries) e.key as String: e.value};
    _collection.log.writes.add(('update', id, fields));
    stored._data.addAll(fields);
  }
}

class _MissingDoc extends Fake
    implements DocumentSnapshot<Map<String, dynamic>> {
  _MissingDoc(this.id);

  @override
  final String id;

  @override
  bool get exists => false;

  @override
  Map<String, dynamic>? data() => null;
}

class _FakeSnapshot extends Fake
    implements QuerySnapshot<Map<String, dynamic>> {
  _FakeSnapshot(this.docs);

  @override
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
}

class _FakeCountQuery extends Fake implements AggregateQuery {
  _FakeCountQuery(this._count);

  final int _count;

  @override
  Future<AggregateQuerySnapshot> get({
    AggregateSource source = AggregateSource.server,
  }) async =>
      _FakeCountSnapshot(_count);
}

class _FakeCountSnapshot extends Fake implements AggregateQuerySnapshot {
  _FakeCountSnapshot(this.count);

  @override
  final int? count;
}
