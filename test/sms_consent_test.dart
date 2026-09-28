import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
        actingUid: 'owner-1',
      );
      expect(result.updated, 0);
      expect(writer.facilityId, isNull);
    });

    test('removal is logged as removed', () async {
      final writer = _RecordingWriter();
      await SmsConsentService.applyBulk(
        facilityId: 'f1',
        tenants: [tenant('a', smsOptInDate: agreed)],
        update: SmsConsentUpdate.remove(at: now),
        writer: writer,
        actingUid: 'owner-1',
      );
      expect(writer.writes.single.fields['smsOptOut'], isTrue);
      expect(writer.writes.single.audit.eventType, 'tenant.smsConsentRemoved');
    });
  });

  group('labels', () {
    test('one wording, naming the facility, attested by the owner', () {
      expect(smsConsentCheckboxLabel('Keepsake Storage'),
          'Keepsake Storage may text this tenant rent reminders and account notices (tenant agreed)');
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

  group('SmsConsentCheckbox', () {
    Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))));

    testWidgets('shows the one label and helper', (tester) async {
      await pump(
          tester,
          SmsConsentCheckbox(
            facilityName: 'Keepsake',
            savedState: SmsConsentState.none,
            value: false,
            onChanged: (_) {},
            method: null,
            onMethodChanged: (_) {},
          ));
      expect(find.text(smsConsentCheckboxLabel('Keepsake')), findsOneWidget);
      expect(find.text(smsConsentHelperText), findsOneWidget);
      expect(find.byKey(const Key('sms-consent-method')), findsNothing);
    });

    testWidgets('asks how they agreed once newly ticked', (tester) async {
      await pump(
          tester,
          SmsConsentCheckbox(
            facilityName: 'Keepsake',
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
            facilityName: 'Keepsake',
            savedState: SmsConsentState.optedOut,
            value: false,
            onChanged: (v) => changed = v,
            method: null,
            onMethodChanged: (_) {},
          ));
      expect(find.text(smsOptedOutText), findsOneWidget);
      final box = tester.widget<Checkbox>(find.byKey(const Key('sms-consent-checkbox')));
      expect(box.onChanged, isNull);
      await tester.tap(find.text(smsOptedOutText));
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
                    facilityName: 'Keepsake', plan: plan, today: now);
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

      expect(find.text('2 tenants will be marked as agreeing to texts from Keepsake.'),
          findsOneWidget);
      expect(find.textContaining('1 tenant with no mobile number'), findsOneWidget);
      expect(find.textContaining('1 tenant who opted out themselves'), findsOneWidget);
      expect(save(tester).onPressed, isNull);

      await tester.tap(find.byKey(const Key('bulk-consent-method-written_lease')));
      await tester.pump();
      expect(save(tester).onPressed, isNull, reason: 'not yet confirmed');
      await tester.tap(find.text('These tenants agreed to receive texts from Keepsake'));
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
