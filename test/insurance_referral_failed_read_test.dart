// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/screens/insurance_screen.dart';
import 'package:sfcapp/services/insurance_service.dart';

import 'support/fake_firestore_store.dart';

/// Serves [FakeStore]'s documents as Firestore, holding a document's `get`
/// until the test completes the Completer in [heldReads] for its path.
class _StoreFirestore extends Fake implements FirebaseFirestore {
  _StoreFirestore(this.store);

  final FakeStore store;
  final Map<String, Completer<void>> heldReads = {};

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _HeldCollection(this, store.collection(path));
}

class _HeldCollection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  _HeldCollection(this._firestore, this._inner);

  final _StoreFirestore _firestore;
  final CollectionReference<Map<String, dynamic>> _inner;

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      _HeldDoc(_firestore, _inner.doc(path));
}

class _HeldDoc extends Fake implements DocumentReference<Map<String, dynamic>> {
  _HeldDoc(this._firestore, this._inner);

  final _StoreFirestore _firestore;
  final DocumentReference<Map<String, dynamic>> _inner;

  @override
  String get path => _inner.path;

  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) =>
      _HeldCollection(_firestore, _inner.collection(collectionPath));

  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([GetOptions? options]) async {
    await _firestore.heldReads[path]?.future;
    return _inner.get(options);
  }

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) =>
      _inner.set(data, options);
}

String _settingsPath(String facilityId) =>
    'facilities/$facilityId/settings/insurance';

/// A facility's saved referral, as the Insurance screen writes it.
Map<String, dynamic> _referral(String name) => {
      'referralName': name,
      'referralUrl': 'https://${name.toLowerCase()}.example.com',
      'referralNotes': 'Mention $name for a discount.',
    };

Future<void> _pumpCard(WidgetTester tester, String facilityId) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: InsuranceReferralCard(facilityId: facilityId),
          ),
        ),
      ),
    );

Finder get _save => find.widgetWithText(FilledButton, 'Save');

Finder _field(String label) => find.widgetWithText(TextField, label);

String _text(WidgetTester tester, String label) =>
    tester.widget<TextField>(_field(label)).controller!.text;

void main() {
  late FakeStore store;
  late _StoreFirestore firestore;

  setUp(() {
    store = FakeStore();
    firestore = _StoreFirestore(store);
    InsuranceService.firestoreForTesting = firestore;
  });

  tearDown(() => InsuranceService.firestoreForTesting = null);

  testWidgets('a failed read offers a retry and no form or Save',
      (tester) async {
    store.put(_settingsPath('fac1'), _referral('Acme'));
    store.refuseRead = (path) => path == _settingsPath('fac1');

    await _pumpCard(tester, 'fac1');
    await tester.pumpAndSettle();

    // Before: the failed load marked the settings loaded, so blank fields and
    // Save showed, and saving wrote '' over the facility's referral.
    expect(find.textContaining("Couldn't load this facility's insurance referral"),
        findsOneWidget);
    expect(_save, findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(store.writes, isEmpty);

    // The read works again: Retry fills the form with what is saved, and a
    // save writes that back rather than blanks.
    store.refuseRead = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(_text(tester, 'Provider Name (e.g. "Example Insurance")'), 'Acme');
    await tester.tap(_save);
    await tester.pumpAndSettle();

    expect(store.writes, ['set ${_settingsPath('fac1')}']);
    final saved = store.data(_settingsPath('fac1'))!;
    expect({for (final key in _referral('Acme').keys) key: saved[key]},
        _referral('Acme'));
    expect(saved, contains('updatedAt'));
  });

  testWidgets('a slower read for the facility switched away from is dropped',
      (tester) async {
    store.put(_settingsPath('fac1'), _referral('Acme'));
    store.put(_settingsPath('fac2'), _referral('Birch'));
    final fac1Read = firestore.heldReads[_settingsPath('fac1')] = Completer();

    await _pumpCard(tester, 'fac1');
    await tester.pump();

    // Still loading: nothing to save yet.
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(_save, findsNothing);

    // The owner picks fac2, whose read comes back first.
    await _pumpCard(tester, 'fac2');
    await tester.pumpAndSettle();
    expect(_text(tester, 'Provider Name (e.g. "Example Insurance")'), 'Birch');

    // fac1's read lands late. Before, it filled fac2's form with fac1's
    // referral, and Save wrote it to fac2.
    fac1Read.complete();
    await tester.pump();
    expect(_save, findsOneWidget);
    expect(_text(tester, 'Provider Name (e.g. "Example Insurance")'), 'Birch');
    expect(_text(tester, 'Website URL (e.g. https://example.com)'),
        'https://birch.example.com');

    await tester.tap(_save);
    await tester.pumpAndSettle();

    expect(store.writes, ['set ${_settingsPath('fac2')}']);
    expect(store.data(_settingsPath('fac2'))!['referralName'], 'Birch');
    expect(store.data(_settingsPath('fac1')), _referral('Acme'));
  });
}
