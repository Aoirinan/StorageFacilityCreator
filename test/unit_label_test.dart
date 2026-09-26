import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/providers/ledger_provider.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/providers/unit_label_provider.dart';
import 'package:sfcapp/screens/ledger_screen.dart';
import 'package:sfcapp/services/facility_service.dart';
import 'package:sfcapp/services/reminder_automation_service.dart';
import 'package:sfcapp/services/statement_service.dart';
import 'package:sfcapp/utils/print_documents.dart';
import 'package:sfcapp/utils/unit_label.dart';

import 'support/fake_facility_collection.dart';

TenantModel _tenant({
  String unitNumber = '12',
  String? unitArea = 'Complex 2',
  String name = 'Jordan Tenant',
}) =>
    TenantModel(
      id: 't1',
      facilityId: 'f1',
      name: name,
      email: 'jordan@example.com',
      phone: '(555) 987-6543',
      unitNumber: unitNumber,
      unitId: unitArea == null ? null : 'u12',
      unitArea: unitArea,
      monthlyRate: 85,
      createdAt: DateTime(2026, 8, 1),
    );

FacilityModel _facility({bool repeat = false}) => FacilityModel(
      id: 'f1',
      name: 'Test Storage',
      ownerUid: 'owner',
      createdAt: DateTime(2026, 1, 1),
      unitNumbersRepeatAcrossAreas: repeat,
    );

String _invoice({String? unitNumber}) => buildInvoiceHtml(
      facilityName: 'Test Storage',
      tenantName: 'Jordan Tenant',
      unitNumber: unitNumber,
      invoiceNumber: 'INV-1',
      issueDateFormatted: 'Sep 1, 2026',
      dueDateFormatted: 'Sep 10, 2026',
      lineItems: const [(description: 'Rent', amount: r'$85.00')],
      subtotalFormatted: r'$85.00',
      totalFormatted: r'$85.00',
      balanceFormatted: r'$85.00',
    );

/// The Messaging screens' quick-template fill before unit labels existed,
/// kept here as the golden the setting-off output must equal.
String _oldQuickMessage(String template, TenantModel t) {
  final n = t.name.trim();
  final first = n.isEmpty ? 'there' : n.split(RegExp(r'\s+')).first;
  return template
      .replaceAll('{{tenant_name}}', t.name)
      .replaceAll('{{name}}', t.name)
      .replaceAll('{{first_name}}', first)
      .replaceAll('{{unit}}', t.unitNumber)
      .replaceAll('{{email}}', t.email)
      .replaceAll('{{phone}}', t.phone);
}

void main() {
  group('parity with functions-shared formatUnitLabel', () {
    // The same table functions-shared/src/test/unitLabel.test.ts runs.
    final parity = jsonDecode(File(
            'functions-shared/src/test/fixtures/unitLabelParity.json')
        .readAsStringSync()) as Map<String, dynamic>;
    final cases = [
      for (final c in parity['cases'] as List)
        Map<String, dynamic>.from(c as Map)
    ];

    test('every case matches the shared table', () {
      expect(cases.length, greaterThan(10));
      for (final c in cases) {
        final style = UnitLabelStyle.values.byName(c['style'] as String);
        expect(
          formatUnitLabel(
            number: c['number'],
            area: c['area'],
            includeArea: c['includeArea'] as bool,
            style: style,
          ),
          c['expected'],
          reason: '$c',
        );
      }
    });

    test('never "()", a double space or a space at either end', () {
      for (final c in cases) {
        final label = formatUnitLabel(
          number: c['number'],
          area: c['area'],
          includeArea: true,
          style: UnitLabelStyle.values.byName(c['style'] as String),
        );
        expect(label, isNot(contains('()')), reason: label);
        expect(label, isNot(contains('  ')), reason: label);
        expect(label, label.trim(), reason: label);
      }
    });
  });

  group('facility setting unitNumbersRepeatAcrossAreas', () {
    test('only an exact true is on; missing is off', () {
      FacilityModel parse(Map<String, dynamic> extra) =>
          FacilityModel.fromFirestore(FakeDoc('f1', {
            'name': 'Test Storage',
            'ownerUid': 'owner',
            'active': true,
            ...extra,
          }));
      expect(parse({}).unitNumbersRepeatAcrossAreas, isFalse);
      expect(parse({'unitNumbersRepeatAcrossAreas': null})
          .unitNumbersRepeatAcrossAreas, isFalse);
      expect(parse({'unitNumbersRepeatAcrossAreas': 'true'})
          .unitNumbersRepeatAcrossAreas, isFalse);
      expect(parse({'unitNumbersRepeatAcrossAreas': 1})
          .unitNumbersRepeatAcrossAreas, isFalse);
      expect(parse({'unitNumbersRepeatAcrossAreas': false})
          .unitNumbersRepeatAcrossAreas, isFalse);
      expect(parse({'unitNumbersRepeatAcrossAreas': true})
          .unitNumbersRepeatAcrossAreas, isTrue);
    });

    test('survives copyWith and the facility list merge', () {
      final on = _facility(repeat: true);
      expect(on.copyWith(name: 'Renamed').unitNumbersRepeatAcrossAreas, isTrue);
      final listed = FacilityService.mergeUserFacilities(
        owned: const [],
        fromRoles: [
          FacilityModel.fromFirestore(FakeDoc('f1', {
            'name': 'Test Storage',
            'ownerUid': 'owner',
            'active': true,
            'unitNumbersRepeatAcrossAreas': true,
          })),
        ],
        includeArchived: false,
      );
      expect(listed.single.unitNumbersRepeatAcrossAreas, isTrue);
    });

    test('is not written by toFirestore, so an old copy cannot turn it off',
        () {
      expect(_facility(repeat: true).toFirestore(),
          isNot(contains('unitNumbersRepeatAcrossAreas')));
      expect(_facility().toFirestore(),
          isNot(contains('unitNumbersRepeatAcrossAreas')));
    });

    test('unitLabelsIncludeArea', () {
      expect(unitLabelsIncludeArea(null), isFalse);
      expect(unitLabelsIncludeArea(_facility()), isFalse);
      expect(unitLabelsIncludeArea(_facility(repeat: true)), isTrue);
    });
  });

  group('tenantUnitLabel', () {
    test('off: the stored number exactly, area or not', () {
      expect(tenantUnitLabel(_tenant(), includeArea: false), '12');
      expect(
          tenantUnitLabel(_tenant(unitNumber: ' 12 '), includeArea: false),
          ' 12 ');
      expect(tenantUnitLabel(_tenant(unitNumber: ''), includeArea: false), '');
    });

    test('on: the number with the tenant unitArea', () {
      expect(tenantUnitLabel(_tenant(), includeArea: true), '12 (Complex 2)');
    });

    test('on: no area is the plain number', () {
      expect(tenantUnitLabel(_tenant(unitArea: null), includeArea: true), '12');
      expect(tenantUnitLabel(_tenant(unitArea: '  '), includeArea: true), '12');
    });

    test("on: the unit doc's area when the tenant has none", () {
      expect(
        tenantUnitLabel(_tenant(unitArea: null),
            includeArea: true, fallbackArea: 'Outdoor'),
        '12 (Outdoor)',
      );
      // The tenant's own unitArea wins.
      expect(
        tenantUnitLabel(_tenant(), includeArea: true, fallbackArea: 'Outdoor'),
        '12 (Complex 2)',
      );
    });

    test('on: no number is still no label', () {
      expect(tenantUnitLabel(_tenant(unitNumber: ''), includeArea: true), '');
    });
  });

  group('statement unit line', () {
    test('off: "Unit: 12", as before', () {
      expect(statementUnitLine(_tenant(), _facility()), 'Unit: 12');
      expect(statementUnitLine(_tenant(unitNumber: 'A-12'), _facility()),
          'Unit: A-12');
    });

    test('on: "Unit: 12 (Complex 2)"', () {
      expect(statementUnitLine(_tenant(), _facility(repeat: true)),
          'Unit: 12 (Complex 2)');
    });

    test('on, no area: "Unit: 12"', () {
      expect(
          statementUnitLine(_tenant(unitArea: null), _facility(repeat: true)),
          'Unit: 12');
    });

    test('no unit number: no line either way', () {
      expect(statementUnitLine(_tenant(unitNumber: ''), _facility()), isNull);
      expect(
          statementUnitLine(
              _tenant(unitNumber: ''), _facility(repeat: true)),
          isNull);
    });

    test('the statement PDF still builds with the setting on', () async {
      final bytes = await StatementService.generateStatementPDF(
        entries: const <LedgerEntry>[],
        tenant: _tenant(),
        facility: _facility(repeat: true),
      );
      expect(bytes, isNotEmpty);
    });
  });

  group('printed invoice (HTML)', () {
    String billTo(String html) => html.substring(
        html.indexOf('<div class="bill-to">'), html.indexOf('<table>'));

    test('off: byte-identical to the stored unit number', () {
      final t = _tenant();
      final before = _invoice(unitNumber: t.unitNumber);
      final after = _invoice(
          unitNumber: tenantUnitLabel(t,
              includeArea: unitLabelsIncludeArea(_facility())));
      expect(after, before);
      expect(billTo(after), contains('<span class="muted">Unit</span> 12</div>'));
    });

    test('on: "Unit 12 (Complex 2)"', () {
      final html = _invoice(
          unitNumber: tenantUnitLabel(_tenant(),
              includeArea: unitLabelsIncludeArea(_facility(repeat: true))));
      expect(billTo(html),
          contains('<span class="muted">Unit</span> 12 (Complex 2)</div>'));
    });

    test('on: the area is HTML-escaped by the invoice, not the label', () {
      final label = tenantUnitLabel(_tenant(unitArea: 'Boat & RV <North>'),
          includeArea: true);
      expect(label, '12 (Boat & RV <North>)');
      expect(billTo(_invoice(unitNumber: label)),
          contains('12 (Boat &amp; RV &lt;North&gt;)'));
    });

    test('on, missing area: plain number', () {
      final html = _invoice(
          unitNumber: tenantUnitLabel(_tenant(unitArea: null), includeArea: true));
      expect(billTo(html), contains('<span class="muted">Unit</span> 12</div>'));
    });
  });

  group('message templates', () {
    const quick = 'Hi {{first_name}} ({{tenant_name}}), past due on unit '
        '{{unit}}. {{email}} {{phone}} {{name}}';

    test('quick messages, off: identical to the old fill', () {
      for (final t in [
        _tenant(),
        _tenant(unitArea: null),
        _tenant(unitNumber: ' B 7 ', name: '  '),
      ]) {
        expect(fillTenantQuickMessage(quick, t, includeArea: false),
            _oldQuickMessage(quick, t));
      }
    });

    test('quick messages, on: {{unit}} names the area', () {
      expect(
        fillTenantQuickMessage('Unit {{unit}} is past due.', _tenant(),
            includeArea: true),
        'Unit 12 (Complex 2) is past due.',
      );
      expect(
        fillTenantQuickMessage('Unit {{unit}} is past due.',
            _tenant(unitArea: null),
            includeArea: true),
        'Unit 12 is past due.',
      );
    });

    test('template variables: unitNumber is the label, unitArea the area', () {
      expect(tenantUnitTemplateVars(_tenant(), includeArea: false),
          {'unitNumber': '12', 'unitArea': 'Complex 2'});
      expect(tenantUnitTemplateVars(_tenant(), includeArea: true),
          {'unitNumber': '12 (Complex 2)', 'unitArea': 'Complex 2'});
      expect(tenantUnitTemplateVars(_tenant(unitArea: null), includeArea: true),
          {'unitNumber': '12', 'unitArea': ''});
    });

    test('reminder schedules fill {{unitNumber}} with the label', () {
      String render(bool on) {
        final vars = reminderScheduleReplacements(
          tenant: _tenant(),
          facilityName: 'Test Storage',
          scheduleName: 'Rent due',
          includeUnitArea: on,
        );
        var out = 'Hello {{tenantName}}, rent for unit {{unitNumber}} is due.';
        vars.forEach((k, v) => out = out.replaceAll('{{$k}}', v));
        return out;
      }

      expect(render(false), 'Hello Jordan Tenant, rent for unit 12 is due.');
      expect(render(true),
          'Hello Jordan Tenant, rent for unit 12 (Complex 2) is due.');
    });
  });

  group('Tenants list unit line', () {
    test('off: exactly the old lines', () {
      final t = _tenant();
      expect(tenantListUnitLine(t, includeArea: false), 'Unit: 12');
      expect(
          tenantListUnitLine(t,
              includeArea: false, areas: const ['Complex 2', 'Outdoor']),
          'Unit: 12 · Complex 2, Outdoor');
      expect(tenantListUnitLine(_tenant(unitNumber: ''), includeArea: false),
          'Unit: ');
    });

    test('on: the area moves into the label; other units\' areas follow', () {
      final t = _tenant();
      expect(
          tenantListUnitLine(t, includeArea: true, areas: const ['Complex 2']),
          'Unit: 12 (Complex 2)');
      expect(
          tenantListUnitLine(t,
              includeArea: true, areas: const ['Complex 2', 'Outdoor']),
          'Unit: 12 (Complex 2) · Outdoor');
      // The list's unit doc supplies the area when the tenant doc has none.
      expect(
          tenantListUnitLine(_tenant(unitArea: null),
              includeArea: true,
              areas: const ['complex 2'],
              labelUnitArea: 'complex 2'),
          'Unit: 12 (complex 2)');
      expect(
          tenantListUnitLine(_tenant(unitArea: null), includeArea: true),
          'Unit: 12');
    });
  });

  group('ledger header', () {
    Future<void> pump(WidgetTester tester, {required bool on}) async {
      final tenant = _tenant();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          ledgerStreamProvider(
            LedgerParams(tenantId: tenant.id, facilityId: tenant.facilityId),
          ).overrideWith((ref) => Stream.value(const <LedgerEntry>[])),
          facilityTenantsProvider('f1')
              .overrideWith((ref) => Stream.value([tenant])),
          unitLabelsIncludeAreaProvider('f1').overrideWith((ref) async => on),
        ],
        child: MaterialApp(home: Scaffold(body: LedgerScreen(tenant: tenant))),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('off: "Unit 12"', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pump(tester, on: false);
      expect(find.text('Unit 12'), findsOneWidget);
      expect(find.textContaining('Complex 2'), findsNothing);
    });

    testWidgets('on: "Unit 12 (Complex 2)"', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pump(tester, on: true);
      expect(find.text('Unit 12 (Complex 2)'), findsOneWidget);
    });
  });
}
