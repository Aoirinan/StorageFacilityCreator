import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/services/sms_consent_service.dart';
import 'package:sfcapp/utils/sms_consent.dart';
import 'package:sfcapp/widgets/sms_consent_bulk_dialog.dart';
import 'package:sfcapp/widgets/sms_consent_checkbox.dart';
import 'package:sfcapp/widgets/sms_consent_chip.dart';

TenantModel tenant(
  String id, {
  String phone = '(903) 555-0101',
  bool smsOptOut = false,
  DateTime? smsOptInDate,
  String smsConsentStatus = 'unknown',
  String? smsConsentSource,
  String? smsConsentMethod,
}) =>
    TenantModel(
      id: id,
      facilityId: 'f1',
      name: 'Tenant $id',
      email: '$id@example.com',
      phone: phone,
      unitNumber: id,
      monthlyRate: 50,
      isActive: true,
      createdAt: DateTime(2026, 1, 1),
      smsOptOut: smsOptOut,
      smsOptInDate: smsOptInDate,
      smsConsentStatus: smsConsentStatus,
      smsConsentSource: smsConsentSource,
      smsConsentMethod: smsConsentMethod,
    );

class _DialogResult {
  bool done = false;
  SmsConsentUpdate? update;
}

/// Stands in for the fresh read: the tenants as stored now.
class _Reader implements SmsConsentTenantReader {
  final Map<String, TenantModel> stored;
  List<String>? asked;
  _Reader(Iterable<TenantModel> tenants) : stored = {for (final t in tenants) t.id: t};

  @override
  Future<List<TenantModel>> read(String facilityId, List<String> tenantIds) async {
    asked = tenantIds;
    return [for (final id in tenantIds) if (stored[id] != null) stored[id]!];
  }
}

class _FailingWriter implements SmsConsentWriter {
  @override
  Future<void> commit(String facilityId, List<SmsConsentWrite> writes) async {
    throw SmsConsentPartialFailure(committed: 200, total: writes.length, cause: 'unavailable');
  }
}

class _RecordingWriter implements SmsConsentWriter {
  String? facilityId;
  List<SmsConsentWrite> writes = [];

  @override
  Future<void> commit(String facilityId, List<SmsConsentWrite> writes) async {
    this.facilityId = facilityId;
    this.writes = writes;
  }
}

void main() {
  final agreed = DateTime(2025, 3, 14);
  final now = DateTime(2026, 9, 27, 10);

  group('consent state reads as the server does', () {
    test('an smsOptInDate or smsConsentStatus opted_in is consent', () {
      expect(smsConsentState(tenant('a', smsOptInDate: agreed)), SmsConsentState.consented);
      expect(smsConsentState(tenant('b', smsConsentStatus: 'opted_in')), SmsConsentState.consented);
      expect(smsConsentState(tenant('c')), SmsConsentState.none);
    });

    test('an opt-out in either field beats a recorded consent', () {
      expect(smsConsentState(tenant('a', smsOptInDate: agreed, smsOptOut: true)),
          SmsConsentState.optedOut);
      expect(
          smsConsentState(
              tenant('b', smsOptInDate: agreed, smsConsentStatus: 'opted_out')),
          SmsConsentState.optedOut);
    });

    test("staff's own removal is not the tenant's opt-out", () {
      expect(
          smsConsentState(tenant('a',
              smsOptOut: true,
              smsConsentStatus: 'opted_out',
              smsConsentSource: SmsConsentSources.staffRemoved)),
          SmsConsentState.removedByStaff);
    });

    test('can receive texts needs consent and a ten-digit number', () {
      expect(canReceiveTexts(tenant('a', smsOptInDate: agreed)), isTrue);
      expect(canReceiveTexts(tenant('b', smsOptInDate: agreed, phone: '555-0101')), isFalse);
      expect(canReceiveTexts(tenant('c')), isFalse);
    });
  });

  group('saving the consent box', () {
    test('re-saving with consent still on writes nothing, so the date they agreed is kept', () {
      // Every save of Edit Tenant used to write smsOptInDate = now.
      expect(smsConsentChange(tenant: tenant('a', smsOptInDate: agreed), ticked: true), isNull);
      expect(
          smsConsentChange(tenant: tenant('b', smsConsentStatus: 'opted_in'), ticked: true),
          isNull);
    });

    test('off to on records consent in both shapes the server reads', () {
      final change = smsConsentChange(
          tenant: tenant('a'), ticked: true, method: SmsConsentMethod.writtenLease, now: now)!;
      final f = change.fields(actingUid: 'owner-1');
      expect(f['smsOptOut'], isFalse);
      expect(f['smsOptOutDate'], FieldValue.delete());
      expect(f['smsOptInDate'], Timestamp.fromDate(now));
      expect(f['smsConsentStatus'], 'opted_in');
      expect(f['smsConsentTimestamp'], Timestamp.fromDate(now));
      expect(f['smsConsentSource'], SmsConsentSources.staffRecorded);
      expect(f['smsConsentMethod'], 'written_lease');
      expect(f['smsConsentRecordedBy'], 'owner-1');
    });

    test('on to off records an opt-out by staff', () {
      final change =
          smsConsentChange(tenant: tenant('a', smsOptInDate: agreed), ticked: false, now: now)!;
      final f = change.fields();
      expect(f['smsOptOut'], isTrue);
      expect(f['smsOptOutDate'], Timestamp.fromDate(now));
      expect(f['smsConsentStatus'], 'opted_out');
      expect(f['smsConsentSource'], SmsConsentSources.staffRemoved);
      expect(f.containsKey('smsOptInDate'), isFalse);
    });

    test("never touches a tenant's own opt-out", () {
      final optedOut = tenant('a', smsOptOut: true, smsConsentSource: 'inbound_stop');
      expect(smsConsentChange(tenant: optedOut, ticked: true), isNull);
      expect(smsConsentChange(tenant: optedOut, ticked: false), isNull);
    });

    test('staff may record consent again after removing it', () {
      final removed = tenant('a',
          smsOptOut: true,
          smsConsentStatus: 'opted_out',
          smsConsentSource: SmsConsentSources.staffRemoved);
      expect(smsConsentChange(tenant: removed, ticked: true)!.grant, isTrue);
      expect(smsConsentChange(tenant: removed, ticked: false), isNull);
    });
  });

  group('bulk plan', () {
    final fresh = tenant('fresh');
    final noPhone = tenant('nophone', phone: '');
    final stop = tenant('stop', smsOptOut: true, smsConsentSource: 'inbound_stop');
    final already = tenant('already', smsOptInDate: agreed);
    final removed = tenant('removed',
        smsOptOut: true, smsConsentStatus: 'opted_out', smsConsentSource: SmsConsentSources.staffRemoved);

    test('recording skips no phone, opt-outs and consents already on file', () {
      final plan = planSmsConsentBulk([fresh, noPhone, stop, already, removed], grant: true);
      expect(plan.toUpdate.map((t) => t.id), ['fresh', 'removed']);
      expect(plan.noPhone.map((t) => t.id), ['nophone']);
      expect(plan.optedOut.map((t) => t.id), ['stop']);
      expect(plan.unchanged.map((t) => t.id), ['already']);
      expect(plan.skipped, 3);
    });

    test('removing touches only tenants with consent', () {
      final plan = planSmsConsentBulk([fresh, stop, already], grant: false);
      expect(plan.toUpdate.map((t) => t.id), ['already']);
      expect(plan.unchanged.map((t) => t.id), ['fresh', 'stop']);
    });
  });

  test('bulk consent: one facility only, and only the selected tenants shown', () {
    expect(bulkSmsConsentAvailable('f1'), isTrue);
    expect(bulkSmsConsentAvailable('all'), isFalse);
    expect(bulkSmsConsentAvailable(''), isFalse);
    // 'c' is selected but hidden by a search.
    final shown = [tenant('a'), tenant('b')];
    expect(visibleSelectedTenants(shown, {'a', 'c'}).map((t) => t.id), ['a']);
  });

  group('SmsConsentService.applyBulk', () {
    test('writes the planned tenants, each with an audit row', () async {
      final writer = _RecordingWriter();
      final update = SmsConsentUpdate.grant(
          consentDate: agreed, method: SmsConsentMethod.other, note: '  2024 addendum ');
      final result = await SmsConsentService.applyBulk(
        facilityId: 'f1',
        tenants: [
          tenant('a'),
          tenant('b', phone: ''),
          tenant('c', smsOptOut: true),
        ],
        update: update,
        writer: writer,
        reader: _Reader([tenant('a'), tenant('b', phone: ''), tenant('c', smsOptOut: true)]),
        actingUid: 'owner-1',
        actingEmail: 'owner@example.com',
      );
      expect(result.updated, 1);
      expect(writer.facilityId, 'f1');
      expect(writer.writes.map((w) => w.tenantId), ['a']);
      final w = writer.writes.single;
      expect(w.fields['smsConsentStatus'], 'opted_in');
      expect(w.fields['smsOptInDate'], Timestamp.fromDate(agreed));
      expect(w.fields['smsConsentMethod'], 'other');
      expect(w.fields['smsConsentNote'], '2024 addendum');
      expect(w.audit.eventType, 'tenant.smsConsentRecorded');
      expect(w.audit.tenantId, 'a');
      expect(w.audit.actorUid, 'owner-1');
      expect(w.audit.after!['method'], 'other');
      // What the audit-log rules require on create.
      final doc = w.audit.toFirestore();
      for (final key in ['facilityId', 'action', 'entityType', 'entityId', 'userId', 'userEmail', 'timestamp', 'changes', 'metadata']) {
        expect(doc.containsKey(key), isTrue, reason: key);
      }
    });

    test('writes nothing when nobody qualifies', () async {
      final writer = _RecordingWriter();
      final result = await SmsConsentService.applyBulk(
        facilityId: 'f1',
        tenants: [tenant('a', smsOptInDate: agreed)],
        update: SmsConsentUpdate.grant(consentDate: agreed),
        writer: writer,
        reader: _Reader([tenant('a', smsOptInDate: agreed)]),
        actingUid: 'owner-1',
      );
      expect(result.updated, 0);
      expect(writer.facilityId, isNull);
    });

    test('plans from a fresh read: a STOP that arrived while the dialog was open is skipped',
        () async {
      final writer = _RecordingWriter();
      // The list showed both without consent; 'b' has since texted STOP.
      final reader = _Reader([
        tenant('a'),
        tenant('b', smsOptOut: true, smsConsentStatus: 'opted_out', smsConsentSource: 'inbound_stop'),
      ]);
      final result = await SmsConsentService.applyBulk(
        facilityId: 'f1',
        tenants: [tenant('a'), tenant('b')],
        update: SmsConsentUpdate.grant(consentDate: agreed),
        writer: writer,
        reader: reader,
        actingUid: 'owner-1',
      );
      expect(reader.asked, ['a', 'b']);
      expect(writer.writes.map((w) => w.tenantId), ['a']);
      expect(result.plan.optedOut.map((t) => t.id), ['b']);
    });

    test('a failure part way reports how many were saved', () async {
      await expectLater(
        SmsConsentService.applyBulk(
          facilityId: 'f1',
          tenants: [for (var i = 0; i < 250; i++) tenant('t$i')],
          update: SmsConsentUpdate.grant(consentDate: agreed),
          writer: _FailingWriter(),
          reader: _Reader([for (var i = 0; i < 250; i++) tenant('t$i')]),
          actingUid: 'owner-1',
        ),
        throwsA(isA<SmsConsentPartialFailure>()
            .having((e) => e.committed, 'committed', 200)
            .having((e) => e.total, 'total', 250)),
      );
      expect(
          smsConsentBulkFailureMessage(
              const SmsConsentPartialFailure(committed: 200, total: 250, cause: 'x'), 'Try again.'),
          '200 of 250 saved; the rest were not. Try again.');
      expect(
          smsConsentBulkFailureMessage(
              const SmsConsentPartialFailure(committed: 0, total: 250, cause: 'x'), 'Try again.'),
          'Nothing was changed: Try again.');
      expect(smsConsentBulkFailureMessage(Exception('x'), 'Try again.'),
          'Nothing was changed: Try again.');
    });

    test('removal is logged as removed', () async {
      final writer = _RecordingWriter();
      await SmsConsentService.applyBulk(
        facilityId: 'f1',
        tenants: [tenant('a', smsOptInDate: agreed)],
        update: SmsConsentUpdate.remove(at: now),
        writer: writer,
        reader: _Reader([tenant('a', smsOptInDate: agreed)]),
        actingUid: 'owner-1',
      );
      expect(writer.writes.single.fields['smsOptOut'], isTrue);
      expect(writer.writes.single.audit.eventType, 'tenant.smsConsentRemoved');
    });
  });

  group('labels', () {
    test('one wording, naming the facility, attested by the owner', () {
      expect(smsConsentCheckboxLabel('Pinewood Storage'),
          'Pinewood Storage may text this tenant rent reminders and account notices (tenant agreed)');
      expect(smsConsentHelperText,
          'Only tick this if the tenant agreed — in writing, on their lease, or by texting START to (855) 526-4544.');
    });

    test('chip and reach line', () {
      expect(smsConsentChipLabel(tenant('a', smsOptInDate: agreed)), 'SMS ✓');
      expect(smsConsentChipLabel(tenant('b')), 'SMS off');
      expect(smsConsentChipLabel(tenant('c', smsOptOut: true)), 'SMS opted out');
      expect(smsReachLine([tenant('a', smsOptInDate: agreed), tenant('b'), tenant('c')]),
          '1 of 3 tenants can receive texts');
    });

    test('the tenant page summary says when and how they agreed', () {
      expect(
          smsConsentSummary(
              tenant('a', smsOptInDate: agreed, smsConsentMethod: 'written_lease')),
          'Can text · agreed 14 Mar 2025 · Written lease');
      expect(smsConsentSummary(tenant('b')), 'No consent recorded');
    });
  });

  group('opt-out wording', () {
    test('says STOP only for a STOP, and names a declined move-in', () {
      final stop = tenant('a',
          smsOptOut: true, smsConsentStatus: 'opted_out', smsConsentSource: 'inbound_stop');
      final declined = tenant('b', smsOptOut: true);
      final csv = tenant('c',
          smsOptOut: true, smsConsentStatus: 'opted_out', smsConsentSource: SmsConsentSources.csvOptOut);
      expect(smsOptedOutLockText(stop),
          'This tenant texted STOP, so the box is locked. Only the tenant can opt back in, by texting START to (855) 526-4544.');
      expect(smsOptedOutLockText(declined), startsWith('This tenant declined texts at move-in, so'));
      expect(smsOptedOutLockText(csv), startsWith('This tenant opted out of texts, so'));
      expect(smsConsentSummary(stop), 'Opted out (tenant texted STOP)');
      expect(smsConsentSummary(declined), 'Declined texts at move-in');
      expect(smsConsentSummary(csv), 'Opted out (per imported spreadsheet)');
      // Locked all the same.
      for (final t in [stop, declined, csv]) {
        expect(smsConsentState(t), SmsConsentState.optedOut);
      }
    });

    test('the START number is the facility\'s own once it is approved', () {
      FacilityModel facility({bool approved = true, String? number}) => FacilityModel(
            id: 'f1',
            name: 'Pinewood',
            ownerUid: 'o',
            createdAt: DateTime(2025),
            textingPlatformApproved: approved,
            twilioPhoneNumberE164: number,
          );
      expect(textingStartNumber(null), '(855) 526-4544');
      expect(textingStartNumber(facility(number: '+19035550188')), '(903) 555-0188');
      expect(textingStartNumber(facility(approved: false, number: '+19035550188')), '(855) 526-4544');
      expect(textingStartNumber(facility()), '(855) 526-4544');
      expect(textingStartNumber(facility(number: '+18555264544')), '(855) 526-4544');
      expect(smsOptedOutLockText(tenant('a', smsOptOut: true), '(903) 555-0188'),
          endsWith('by texting START to (903) 555-0188.'));
      expect(smsConsentHelper('(903) 555-0188'), endsWith('texting START to (903) 555-0188.'));
    });
  });

  group('SmsConsentCheckbox', () {
    Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))));

    testWidgets('shows the one label and helper', (tester) async {
      await pump(
          tester,
          SmsConsentCheckbox(
            facilityName: 'Pinewood',
            savedState: SmsConsentState.none,
            value: false,
            onChanged: (_) {},
            method: null,
            onMethodChanged: (_) {},
          ));
      expect(find.text(smsConsentCheckboxLabel('Pinewood')), findsOneWidget);
      expect(find.text(smsConsentHelperText), findsOneWidget);
      expect(find.byKey(const Key('sms-consent-method')), findsNothing);
    });

    testWidgets('asks how they agreed once newly ticked', (tester) async {
      await pump(
          tester,
          SmsConsentCheckbox(
            facilityName: 'Pinewood',
            savedState: SmsConsentState.none,
            value: true,
            onChanged: (_) {},
            method: null,
            onMethodChanged: (_) {},
          ));
      expect(find.byKey(const Key('sms-consent-method')), findsOneWidget);
    });

    testWidgets("a tenant's own opt-out locks the box", (tester) async {
      bool? changed;
      await pump(
          tester,
          SmsConsentCheckbox(
            facilityName: 'Pinewood',
            savedState: SmsConsentState.optedOut,
            value: false,
            onChanged: (v) => changed = v,
            method: null,
            onMethodChanged: (_) {},
          ));
      final lock = find.textContaining('so the box is locked');
      expect(lock, findsOneWidget);
      final box = tester.widget<Checkbox>(find.byKey(const Key('sms-consent-checkbox')));
      expect(box.onChanged, isNull);
      await tester.tap(lock);
      expect(changed, isNull);
    });
  });

  group('Record SMS consent dialog', () {
    Future<_DialogResult> open(WidgetTester tester, SmsConsentBulkPlan plan) async {
      final holder = _DialogResult();
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                holder.update = await showRecordSmsConsentDialog(context,
                    facilityName: 'Pinewood', plan: plan, today: now);
                holder.done = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return holder;
    }

    FilledButton save(WidgetTester tester) =>
        tester.widget<FilledButton>(find.byKey(const Key('bulk-consent-save')));

    testWidgets('records only once a method is chosen and the owner confirms',
        (tester) async {
      final plan = planSmsConsentBulk([
        tenant('a'),
        tenant('b'),
        tenant('c', phone: ''),
        tenant('d', smsOptOut: true),
      ], grant: true);
      final result = await open(tester, plan);

      expect(find.text('2 tenants will be marked as agreeing to texts from Pinewood.'),
          findsOneWidget);
      expect(find.textContaining('1 tenant with no phone number that can take texts'), findsOneWidget);
      expect(find.textContaining('1 tenant who opted out or declined texts themselves'), findsOneWidget);
      expect(save(tester).onPressed, isNull);

      await tester.tap(find.byKey(const Key('bulk-consent-method-written_lease')));
      await tester.pump();
      expect(save(tester).onPressed, isNull, reason: 'not yet confirmed');
      await tester.tap(find.text('These tenants agreed to receive texts from Pinewood'));
      await tester.pump();
      expect(save(tester).onPressed, isNotNull);

      await tester.tap(find.byKey(const Key('bulk-consent-save')));
      await tester.pumpAndSettle();
      expect(result.done, isTrue);
      final update = result.update!;
      expect(update.grant, isTrue);
      expect(update.method, SmsConsentMethod.writtenLease);
      expect(update.date, now);
    });

    testWidgets('Other needs a note', (tester) async {
      final result = await open(tester, planSmsConsentBulk([tenant('a')], grant: true));
      await tester.tap(find.byKey(const Key('bulk-consent-method-other')));
      await tester.tap(find.byKey(const Key('bulk-consent-confirm')));
      await tester.pump();
      expect(save(tester).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('bulk-consent-note')), 'Text from tenant');
      await tester.pump();
      expect(save(tester).onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('bulk-consent-save')));
      await tester.pumpAndSettle();
      expect(result.done, isTrue);
      final update = result.update!;
      expect(update.method, SmsConsentMethod.other);
      expect(update.note, 'Text from tenant');
    });

    testWidgets('cancel records nothing', (tester) async {
      final result = await open(tester, planSmsConsentBulk([tenant('a')], grant: true));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result.done, isTrue);
      expect(result.update, isNull);
    });
  });
}
