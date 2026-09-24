// The fakes below implement cloud_firestore's @sealed reference, query and
// snapshot classes so tests can run services that reach several collections
// and subcollections (PermissionService's invites and roles); nothing outside
// tests sees them.
// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

/// An in-memory Firestore keyed by document path ('facilities/f1/invites/i1')
/// that answers what the app's permission code asks of it: equality `where`,
/// `limit`, `get` on collections and collection groups, and `doc`, `add`,
/// `get`, `set` (with merge), `update` and `delete` on documents, plus
/// `parent` and `collection` for walking paths. Anything else fails the test.
class FakeStore {
  final Map<String, Map<String, dynamic>> _docs = {};
  int _nextId = 0;

  /// Writes to a path this matches are refused the way the rules refuse
  /// them (permission-denied).
  bool Function(String path)? refuseWrite;

  void _checkWrite(String path) {
    if (refuseWrite?.call(path) ?? false) {
      throw FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied');
    }
  }

  /// Every write, in order: 'set PATH', 'update PATH' or 'delete PATH'.
  final List<String> writes = [];

  /// Every query run, as 'COLLECTION field=value ...' (COLLECTION is the
  /// collection's path, or the group's id).
  final List<String> queries = [];

  void put(String path, Map<String, dynamic> data) => _docs[path] = _copy(data);

  /// The stored data at [path], or null when there is no doc.
  Map<String, dynamic>? data(String path) => _docs[path];

  /// The ids of the docs directly under [collectionPath].
  List<String> idsIn(String collectionPath) => [
        for (final path in _docs.keys)
          if (_parentOf(path) == collectionPath) path.split('/').last,
      ];

  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _StoreCollection(this, path);

  Query<Map<String, dynamic>> collectionGroup(String collectionId) => _StoreQuery(
        this,
        collectionId,
        (docPath) => _parentOf(docPath).split('/').last == collectionId,
      );

  static String _parentOf(String docPath) =>
      docPath.substring(0, docPath.lastIndexOf('/'));

  static Map<String, dynamic> _copy(Map<String, dynamic> data) => {
        for (final e in data.entries)
          e.key: e.value is Map ? _copy(Map<String, dynamic>.from(e.value as Map)) : e.value,
      };

  // set(merge: true): nested maps merge, FieldValue.delete() removes the key.
  static void _merge(Map<String, dynamic> into, Map<String, dynamic> from) {
    for (final e in from.entries) {
      final value = e.value;
      if (value == FieldValue.delete()) {
        into.remove(e.key);
      } else if (value is Map && into[e.key] is Map) {
        final nested = Map<String, dynamic>.from(into[e.key] as Map);
        _merge(nested, Map<String, dynamic>.from(value));
        into[e.key] = nested;
      } else if (value is Map) {
        final nested = <String, dynamic>{};
        _merge(nested, Map<String, dynamic>.from(value));
        into[e.key] = nested;
      } else {
        into[e.key] = value;
      }
    }
  }
}

class _StoreQuery extends Fake implements Query<Map<String, dynamic>> {
  _StoreQuery(this._store, this._label, this._inScope,
      [this._filters = const [], this._limit]);

  final FakeStore _store;
  final String _label;
  final bool Function(String docPath) _inScope;
  final List<(String, Object?)> _filters;
  final int? _limit;

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
      throw UnimplementedError('FakeStore only supports isEqualTo');
    }
    return _StoreQuery(_store, _label, _inScope, [..._filters, (field as String, isEqualTo)], _limit);
  }

  @override
  Query<Map<String, dynamic>> limit(int limit) =>
      _StoreQuery(_store, _label, _inScope, _filters, limit);

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) async {
    _store.queries.add([_label, for (final (f, v) in _filters) '$f=$v'].join(' '));
    final paths = [
      for (final e in _store._docs.entries)
        if (_inScope(e.key) &&
            _filters.every((f) => e.value.containsKey(f.$1) && e.value[f.$1] == f.$2))
          e.key,
    ]..sort();
    final limit = _limit;
    final served = limit == null ? paths : paths.take(limit);
    return _StoreSnapshot([
      for (final path in served) _StoreDoc(_StoreDocRef(_store, path), _store._docs[path]!),
    ]);
  }
}

class _StoreCollection extends _StoreQuery implements CollectionReference<Map<String, dynamic>> {
  _StoreCollection(FakeStore store, this.path)
      : super(store, path, (docPath) => FakeStore._parentOf(docPath) == path);

  @override
  final String path;

  @override
  String get id => path.split('/').last;

  @override
  DocumentReference<Map<String, dynamic>>? get parent {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? null : _StoreDocRef(_store, path.substring(0, slash));
  }

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      _StoreDocRef(_store, '${this.path}/${path ?? 'auto-${_store._nextId++}'}');

  @override
  Future<DocumentReference<Map<String, dynamic>>> add(Map<String, dynamic> data) async {
    final ref = doc();
    await ref.set(data);
    return ref;
  }
}

class _StoreDocRef extends Fake implements DocumentReference<Map<String, dynamic>> {
  _StoreDocRef(this._store, this.path);

  final FakeStore _store;

  @override
  final String path;

  @override
  String get id => path.split('/').last;

  @override
  CollectionReference<Map<String, dynamic>> get parent =>
      _StoreCollection(_store, FakeStore._parentOf(path));

  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) =>
      _StoreCollection(_store, '$path/$collectionPath');

  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([GetOptions? options]) async {
    final data = _store._docs[path];
    if (data == null) return _StoreMissing(this);
    return _StoreDoc(this, data);
  }

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    _store._checkWrite(path);
    _store.writes.add('set $path');
    final merged = options?.merge == true ? (_store._docs[path] ?? <String, dynamic>{}) : <String, dynamic>{};
    FakeStore._merge(merged, data);
    _store._docs[path] = merged;
  }

  @override
  Future<void> update(Map<Object, Object?> data) async {
    final stored = _store._docs[path];
    if (stored == null) {
      throw FirebaseException(plugin: 'cloud_firestore', code: 'not-found');
    }
    _store._checkWrite(path);
    _store.writes.add('update $path');
    FakeStore._merge(stored, {for (final e in data.entries) e.key as String: e.value});
  }

  @override
  Future<void> delete() async {
    _store._checkWrite(path);
    _store.writes.add('delete $path');
    _store._docs.remove(path);
  }
}

class _StoreDoc extends Fake implements QueryDocumentSnapshot<Map<String, dynamic>> {
  _StoreDoc(this.reference, Map<String, dynamic> data) : _data = FakeStore._copy(data);

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

class _StoreMissing extends Fake implements DocumentSnapshot<Map<String, dynamic>> {
  _StoreMissing(this.reference);

  @override
  final DocumentReference<Map<String, dynamic>> reference;

  @override
  String get id => reference.id;

  @override
  bool get exists => false;

  @override
  Map<String, dynamic>? data() => null;
}

class _StoreSnapshot extends Fake implements QuerySnapshot<Map<String, dynamic>> {
  _StoreSnapshot(this.docs);

  @override
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
}
