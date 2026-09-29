import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/address_model.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/utils/mailing_address_edit.dart';

Address address({
  String id = 'a1',
  AddressType type = AddressType.mailing,
  bool isPrimary = true,
  String street1 = '12 Example Ave',
  String? street2,
  String city = '',
  String state = '',
  String zipCode = '',
  String? country,
  String? notes,
}) =>
    Address(
      id: id,
      type: type,
      street1: street1,
      street2: street2,
      city: city,
      state: state,
      zipCode: zipCode,
      country: country,
      isPrimary: isPrimary,
      notes: notes,
      createdAt: DateTime(2026, 9, 26),
    );

const typed = MailingAddressFields(
  street1: 'PO Box 12',
  city: 'Anytown',
  state: 'ND',
  zipCode: '79401',
);

/// The tenant doc as stored, and what setMailingAddress writes to it.
class _Store implements TenantRecordsStore {
  Map<String, dynamic> doc;
  final writes = <Map<String, dynamic>>[];
  _Store(this.doc);

  @override
  Future<Map<String, dynamic>?> tenant(String tenantId) async => doc;

  @override
  Future<void> updateTenant(String tenantId, Map<String, dynamic> fields) async {
    writes.add(fields);
    doc = {...doc, ...fields};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingEffects extends TenantUpdateEffects {
  final audits = <Map<String, dynamic>>[];

  @override
  Future<void> audit({
    required String facilityId,
    required String tenantId,
    Map<String, dynamic>? before,
    Map<String, dynamic>? after,
    required Map<String, dynamic> metadata,
  }) async {
    audits.add({'before': before, 'after': after, 'metadata': metadata});
  }
}

void main() {
  final now = DateTime(2026, 9, 28, 14, 30);

  group('replaceMailingAddress', () {
    test('a street-only import gets its city, state and ZIP; id and createdAt stay', () {
      // What a workbook import leaves: the street, nothing else.
      final imported = address(id: 'imp-1');
      final result = replaceMailingAddress([imported], typed, now);

      expect(result, hasLength(1));
      final saved = result.single;
      expect(saved.id, 'imp-1');
      expect(saved.createdAt, imported.createdAt);
      expect(saved.updatedAt, now);
      expect(saved.type, AddressType.mailing);
      expect(saved.isPrimary, isTrue);
      expect(saved.street1, 'PO Box 12');
      expect(saved.street2, isNull);
      expect(saved.city, 'Anytown');
      expect(saved.state, 'ND');
      expect(saved.zipCode, '79401');
    });

    test('keeps the other entries and only swaps the one the page shows', () {
      final other = address(id: 'alt', type: AddressType.alternate, isPrimary: false, street1: '1 Elm St');
      final shown = address(id: 'main');
      final result = replaceMailingAddress([other, shown], typed, now);

      expect(result.map((a) => a.id), ['alt', 'main']);
      expect(identical(result.first, other), isTrue, reason: 'untouched, not copied');
      expect(result.last.street1, 'PO Box 12');
    });

    test('keeps country and notes; clears an Apt that was emptied', () {
      final withApt = address(street2: 'Apt 4', country: 'US', notes: 'gate side');
      final saved = replaceMailingAddress([withApt], typed, now).single;
      expect(saved.street2, isNull, reason: 'copyWith could not clear it');
      expect(saved.country, 'US');
      expect(saved.notes, 'gate side');
    });

    test('a tenant with no address gets a new primary mailing entry', () {
      final result = replaceMailingAddress(const [], typed, now);
      final added = result.single;
      expect(added.type, AddressType.mailing);
      expect(added.isPrimary, isTrue);
      expect(added.id, isNotEmpty);
      expect(added.createdAt, now);
      expect(added.updatedAt, isNull);
      expect(added.formattedAddress, 'PO Box 12\nAnytown, ND 79401');
    });

    test('an entry with an empty id (online move-in) is still replaced, not doubled', () {
      final moveIn = address(id: '');
      final result = replaceMailingAddress([moveIn], typed, now);
      expect(result, hasLength(1));
      expect(result.single.id, '');
      expect(result.single.city, 'Anytown');
    });

    test('trims what was typed and leaves a blank Apt off', () {
      const padded = MailingAddressFields(
        street1: '  PO Box 12 ',
        street2: '   ',
        city: ' Anytown',
        state: 'ND ',
        zipCode: ' 79401 ',
      );
      final saved = replaceMailingAddress([address()], padded, now).single;
      expect(saved.street1, 'PO Box 12');
      expect(saved.street2, isNull);
      expect(saved.city, 'Anytown');
      expect(saved.state, 'ND');
      expect(saved.zipCode, '79401');
      expect(saved.toMap().containsKey('street2'), isFalse);
    });

    test('blank fields mean no address: the same as Remove', () {
      final other = address(id: 'alt', type: AddressType.alternate, isPrimary: false);
      final result = replaceMailingAddress([address(id: 'main'), other], MailingAddressFields.none, now);
      expect(result.map((a) => a.id), ['alt']);
      // A street of spaces is blank too: TenantModel drops it on read.
      const spaces = MailingAddressFields(street1: '  ', city: 'Anytown', state: 'ND', zipCode: '79401');
      expect(spaces.isBlank, isTrue);
      expect(replaceMailingAddress([address()], spaces, now), isEmpty);
    });
  });

  group('removeMailingAddress', () {
    test('drops the shown entry and keeps the rest', () {
      final other = address(id: 'alt', type: AddressType.alternate, isPrimary: false);
      expect(removeMailingAddress([address(id: 'main'), other]).map((a) => a.id), ['alt']);
    });

    test('nothing to remove: unchanged', () {
      expect(removeMailingAddress(const []), isEmpty);
    });
  });

  group('currentMailingAddress', () {
    test('is the entry the invoice prints: primary first, else mailing', () {
      final billing = address(id: 'bill', type: AddressType.billing, isPrimary: false);
      final mailing = address(id: 'mail', isPrimary: false);
      final primary = address(id: 'prim', type: AddressType.other);
      expect(currentMailingAddress([mailing, billing, primary])!.id, 'prim');
      expect(currentMailingAddress([mailing, billing])!.id, 'bill');
      expect(currentMailingAddress([mailing])!.id, 'mail');
      expect(currentMailingAddress(const []), isNull);
    });
  });

  group('TenantService.setMailingAddress', () {
    // Nobody signed in unless the test passes actingUid. Without this the
    // "refuses" test below would read FirebaseAuth.instance, which throws
    // for want of a Firebase app before the guard runs, and pass whether
    // or not the guard is there.
    setUp(() => TenantService.authForTesting = MockFirebaseAuth(signedIn: false));
    tearDown(() => TenantService.authForTesting = null);

    test('writes the whole array and updatedAt, with the audit row updateTenant writes', () async {
      final store = _Store({'name': 'Pat Example', 'isActive': true});
      final fx = _RecordingEffects();
      final addresses = replaceMailingAddress(const [], typed, now);

      await TenantService.setMailingAddress(
        facilityId: 'f1',
        tenantId: 't1',
        addresses: addresses,
        records: store,
        effects: fx,
        actingUid: 'owner-1',
      );

      final written = store.writes.single;
      expect(written.keys, ['addresses', 'updatedAt']);
      expect(written['updatedAt'], FieldValue.serverTimestamp());
      final entry = (written['addresses'] as List).single as Map<String, dynamic>;
      expect(entry['type'], 'mailing');
      expect(entry['isPrimary'], isTrue);
      expect(entry['street1'], 'PO Box 12');
      expect(entry['city'], 'Anytown');
      expect(entry['state'], 'ND');
      expect(entry['zipCode'], '79401');
      expect(entry['createdAt'], Timestamp.fromDate(now));

      final audit = fx.audits.single;
      expect(audit['metadata'], {'fieldsChanged': ['addresses', 'updatedAt']});
      expect((audit['before'] as Map)['name'], 'Pat Example');
      expect((audit['after'] as Map).containsKey('addresses'), isTrue);
    });

    test('removing writes an empty array, not a missing field', () async {
      final store = _Store({'name': 'Pat Example'});
      await TenantService.setMailingAddress(
        facilityId: 'f1',
        tenantId: 't1',
        addresses: const [],
        records: store,
        effects: _RecordingEffects(),
        actingUid: 'owner-1',
      );
      expect(store.writes.single['addresses'], isEmpty);
    });

    test('refuses when nobody is signed in, before writing', () async {
      final store = _Store({});
      await expectLater(
        TenantService.setMailingAddress(
          facilityId: 'f1',
          tenantId: 't1',
          addresses: const [],
          records: store,
          effects: _RecordingEffects(),
        ),
        throwsA(predicate((e) => e.toString().contains('Not signed in'))),
      );
      expect(store.writes, isEmpty);
    });
  });
}
