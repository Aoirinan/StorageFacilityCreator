import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/utils/sms_consent.dart';
import 'package:sfcapp/utils/sms_consent_import.dart';

/// The tenant doc as stored, and what updateTenant writes to it. Nothing
/// else of the store is used by a contact-only save.
class _Store implements TenantRecordsStore {
  Map<String, dynamic> doc;
  final writes = <Map<String, dynamic>>[];
  _Store(this.doc);

  @override
  Future<Map<String, dynamic>?> tenant(String tenantId) async => doc;

  @override
  Future<void> updateTenant(String tenantId, Map<String, dynamic> fields) async {
    writes.add(fields);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoEffects extends TenantUpdateEffects {
  const _NoEffects();

  @override
  Future<void> audit({
    required String facilityId,
    required String tenantId,
    Map<String, dynamic>? before,
    Map<String, dynamic>? after,
    required Map<String, dynamic> metadata,
  }) async {}
}

/// The edit screens build the consent change from the tenant as the form
/// opened. updateTenant checks it again against the tenant as stored now.
void main() {
  final agreed = DateTime(2025, 3, 14);

  Future<({_Store store, String? notice})> save(
      Map<String, dynamic> stored, SmsConsentUpdate change) async {
    final store = _Store({'name': 'Ada Park', 'isActive': true, ...stored});
    final notice = await TenantService.updateTenant(
      facilityId: 'f1',
      tenantId: 't1',
      name: 'Ada Park',
      smsConsent: change,
      records: store,
      effects: const _NoEffects(),
      actingUid: 'owner-1',
    );
    return (store: store, notice: notice);
  }

  test('a STOP that arrived while the form was open is not undone', () async {
    final r = await save(
      {'smsOptOut': true, 'smsConsentStatus': 'opted_out', 'smsConsentSource': 'inbound_stop'},
      SmsConsentUpdate.grant(consentDate: agreed),
    );
    final written = r.store.writes.single;
    expect(written['name'], 'Ada Park', reason: 'the rest of the edit still saves');
    expect(written.containsKey('smsOptOut'), isFalse);
    expect(written.containsKey('smsConsentStatus'), isFalse);
    expect(r.notice, 'SMS consent was not changed: the tenant texted STOP, and only they can opt back in.');
  });

  test('a consent recorded meanwhile keeps its date', () async {
    final r = await save(
      {'smsOptInDate': Timestamp.fromDate(agreed), 'smsConsentStatus': 'opted_in'},
      SmsConsentUpdate.grant(consentDate: DateTime(2026, 9, 27)),
    );
    expect(r.store.writes.single.containsKey('smsOptInDate'), isFalse);
    expect(r.notice, isNull);
  });

  test('a consent change that still applies is written', () async {
    final r = await save({}, SmsConsentUpdate.grant(consentDate: agreed));
    expect(r.store.writes.single['smsConsentStatus'], 'opted_in');
    expect(r.store.writes.single['smsConsentSource'], SmsConsentSources.staffRecorded);
    final removed = await save(
      {'smsOptInDate': Timestamp.fromDate(agreed)},
      SmsConsentUpdate.remove(at: DateTime(2026, 9, 27)),
    );
    expect(removed.store.writes.single['smsOptOut'], isTrue);
    expect(removed.store.writes.single['smsConsentSource'], SmsConsentSources.staffRemoved);
  });

  group('CSV import consent column', () {
    test('an unambiguous opt-out word is an opt-out, not just "no consent"', () {
      for (final value in ['Opted out', 'STOP', 'opt-out', 'opt out', 'declined', 'refused', 'unsubscribed']) {
        final parsed = parseSmsConsent(consentValue: value);
        expect(parsed.optedOut, isTrue, reason: value);
        expect(parsed.optedIn, isFalse, reason: value);
      }
    });

    test('a bare no / N, blank, false, 0 and n/a are only "not recorded"', () {
      // Y/N exports often mean N = consent never collected; locking those
      // tenants would stop staff recording consent later.
      for (final value in ['No', 'n', 'N', '', 'false', '0', 'n/a', '-', 'maybe']) {
        expect(parseSmsConsent(consentValue: value).optedOut, isFalse, reason: value);
      }
      expect(parseSmsConsent(consentValue: 'yes').optedOut, isFalse);
    });
  });
}
