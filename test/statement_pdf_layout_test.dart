import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:sfcapp/models/address_model.dart';
import 'package:sfcapp/models/document_logo_layout.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/services/pdf_letterhead.dart';
import 'package:sfcapp/services/statement_service.dart';
import 'package:sfcapp/utils/statement_lines.dart';

FacilityModel _facility({
  String? logoUrl,
  String? mailing,
  String? message,
  bool repeat = false,
  DocumentLogoLayout documentLogo = DocumentLogoLayout.defaults,
}) =>
    FacilityModel(
      id: 'f1',
      name: 'Keepsake Self Storage and Boat & RV Parking',
      ownerUid: 'owner',
      createdAt: DateTime(2026, 1, 1),
      address: '1200 County Road 45\nSpringfield, MO 65801',
      mailingAddress: mailing,
      statementMessage: message,
      phone: '(555) 123-4567',
      email: 'office@keepsake.example',
      logoUrl: logoUrl,
      documentLogo: documentLogo,
      unitNumbersRepeatAcrossAreas: repeat,
    );

/// A 4x1 PNG: wide, like most logos with the business name in them.
final _wideLogoPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAABCAIAAAB2XpiaAAAADUlEQVR4nGOQs+qCIwAVUQOJi/CUgQAAAABJRU5ErkJggg==');

/// The letterhead alone on a page, uncompressed so its text can be found in
/// the bytes.
Future<String> _letterheadPdf(FacilityModel facility, {bool withLogo = true}) async {
  final doc = pw.Document(compress: false);
  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat.letter,
    margin: const pw.EdgeInsets.all(72),
    build: (_) => PdfLetterhead.build(
      facility: facility,
      title: 'Account Statement',
      titleDetails: const ['Date: 09/25/2026'],
      logo: withLogo ? pw.MemoryImage(_wideLogoPng) : null,
    ),
  ));
  return latin1.decode(await doc.save());
}

final _tenant = TenantModel(
  id: 't1',
  facilityId: 'f1',
  name: 'Jordan Tenant',
  email: 'jordan@example.com',
  phone: '(555) 987-6543',
  unitNumber: 'A-12',
  monthlyRate: 85,
  createdAt: DateTime(2026, 8, 1),
);

/// A tenant on paper: a mailing address, a phone and no email, like most
/// tenants whose statements are mailed.
final _mailedTenant = TenantModel(
  id: 't2',
  facilityId: 'f1',
  name: 'Pat Example',
  email: '',
  phone: '(555) 010-0199',
  unitNumber: 'C2-6',
  unitId: 'u6',
  unitArea: 'Complex 2',
  monthlyRate: 110,
  createdAt: DateTime(2026, 1, 1),
  addresses: [
    Address(
      id: 'a1',
      type: AddressType.mailing,
      street1: '12 Example Ave',
      city: 'Anytown',
      state: 'ND',
      zipCode: '79401',
      isPrimary: true,
      createdAt: DateTime(2026, 1, 1),
    ),
  ],
);

LedgerEntry _entry(String id, LedgerEntryType type, double amount, DateTime at,
        String description,
        {LedgerEntryStatus status = LedgerEntryStatus.posted}) =>
    LedgerEntry(
      id: id,
      tenantId: 't1',
      facilityId: 'f1',
      type: type,
      amount: amount,
      description: description,
      entryDate: at,
      status: status,
      createdAt: at,
      createdBy: 'owner',
    );

UnitModel _unit(String id, String number, {String? area, UnitStatus status = UnitStatus.occupied}) =>
    UnitModel(
      id: id,
      facilityId: 'f1',
      unitNumber: number,
      unitType: 'standard',
      status: status,
      tenantId: 't2',
      monthlyRate: 55,
      area: area,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      createdBy: 'owner',
    );

/// One statement in an uncompressed document, so its text can be read back.
Future<String> _statementPdf({
  required List<LedgerEntry> entries,
  required TenantModel tenant,
  required FacilityModel facility,
  List<String>? unitLabels,
  DateTime? startDate,
  DateTime? endDate,
}) async {
  final doc = pw.Document(compress: false);
  doc.addPage(StatementService.buildStatementPage(
    lines: buildStatementLines(entries, startDate: startDate, endDate: endDate),
    tenant: tenant,
    unitLabels: unitLabels ?? statementUnitLabels(tenant, facility),
    facility: facility,
    printedOn: DateTime(2026, 9, 28),
    startDate: startDate,
    endDate: endDate,
  ));
  return latin1.decode(await doc.save());
}

/// A line of text on the page: its baseline (points from the bottom) and
/// its words left to right.
typedef _Line = ({double y, String text});

/// The pdf package writes each word as `x y Td [(word)]TJ`, positioned
/// inside whatever `cm` translations its widgets pushed (`q`/`Q`), so the
/// words are mapped through that matrix to page coordinates and grouped by
/// baseline: the page's lines, so a test can say what sits under what.
/// Table cells on one row share a baseline and read as one line. For a
/// one-page statement only: page two would start its coordinates over.
List<_Line> _textLines(String pdf) {
  const num = r'(-?[\d.]+)';
  final ops = RegExp(
    '(?<q>\\bq\\b)|(?<restore>\\bQ\\b)|'
    '(?<cm>$num $num $num $num $num $num cm)|'
    '(?<text>$num $num Td \\[\\((.*?)\\)\\]TJ)',
  );
  // [a, b, c, d, e, f]: x' = a x + c y + e, y' = b x + d y + f.
  var ctm = <double>[1, 0, 0, 1, 0, 0];
  final saved = <List<double>>[];
  final words = <({double x, double y, String word})>[];
  for (final m in ops.allMatches(pdf)) {
    if (m.namedGroup('q') != null) {
      saved.add(ctm);
    } else if (m.namedGroup('restore') != null) {
      if (saved.isNotEmpty) ctm = saved.removeLast();
    } else if (m.namedGroup('cm') != null) {
      // Named groups count in the numbering: q 1, Q 2, cm 3 with its six
      // numbers 4-9, text 10 with x, y and the word 11-13.
      final n = [for (var i = 4; i <= 9; i++) double.parse(m.group(i)!)];
      ctm = [
        n[0] * ctm[0] + n[1] * ctm[2],
        n[0] * ctm[1] + n[1] * ctm[3],
        n[2] * ctm[0] + n[3] * ctm[2],
        n[2] * ctm[1] + n[3] * ctm[3],
        n[4] * ctm[0] + n[5] * ctm[2] + ctm[4],
        n[4] * ctm[1] + n[5] * ctm[3] + ctm[5],
      ];
    } else {
      final x = double.parse(m.group(11)!);
      final y = double.parse(m.group(12)!);
      words.add((
        x: ctm[0] * x + ctm[2] * y + ctm[4],
        y: double.parse((ctm[1] * x + ctm[3] * y + ctm[5]).toStringAsFixed(1)),
        word: m.group(13)!.replaceAll(r'\(', '(').replaceAll(r'\)', ')'),
      ));
    }
  }
  // Top of the page first. Bold and regular Helvetica sit their baselines a
  // hair apart in one table row, so words within 2pt are one line.
  words.sort((a, b) => b.y.compareTo(a.y));
  final lines = <_Line>[];
  var lineWords = <({double x, double y, String word})>[];
  void closeLine() {
    if (lineWords.isEmpty) return;
    lineWords.sort((a, b) => a.x.compareTo(b.x));
    lines.add((y: lineWords.first.y, text: lineWords.map((w) => w.word).join(' ')));
    lineWords = [];
  }
  for (final w in words) {
    if (lineWords.isNotEmpty && (lineWords.first.y - w.y).abs() > 2) {
      closeLine();
    }
    lineWords.add(w);
  }
  closeLine();
  return lines;
}

_Line _lineWith(List<_Line> lines, String text) =>
    lines.firstWhere((l) => l.text.contains(text),
        orElse: () => throw StateError('no line contains "$text" in:\n'
            '${lines.map((l) => l.text).join('\n')}'));

int _linesWith(List<_Line> lines, String text) =>
    lines.where((l) => l.text.contains(text)).length;

void main() {
  test('remit address prefers the mailing address', () {
    expect(PdfLetterhead.remitAddress(_facility()),
        '1200 County Road 45\nSpringfield, MO 65801');
    expect(PdfLetterhead.remitAddress(_facility(mailing: 'PO Box 9')),
        'PO Box 9');
    expect(PdfLetterhead.remitAddress(_facility(mailing: '  ')),
        '1200 County Road 45\nSpringfield, MO 65801');
  });

  test('the letterhead prints its mailing line only for a separate address',
      () {
    expect(PdfLetterhead.printsMailingLine(_facility()), isFalse);
    expect(PdfLetterhead.printsMailingLine(_facility(mailing: '  ')), isFalse);
    expect(
        PdfLetterhead.printsMailingLine(
            _facility(mailing: '1200 County Road 45\nSpringfield, MO 65801')),
        isFalse);
    expect(PdfLetterhead.printsMailingLine(_facility(mailing: 'PO Box 9')),
        isTrue);
  });

  test('statement renders with a long name, mailing address and message',
      () async {
    // SFC_PDF_OUT / SFC_LOGO_URL let a person look at the result; without
    // them this only proves the page lays out without throwing.
    final logoUrl = Platform.environment['SFC_LOGO_URL'];
    final facility = _facility(
      logoUrl: logoUrl,
      mailing: 'PO Box 482\nSpringfield, MO 65801',
      message: 'Rent is due on the 1st. Call us any time with questions.',
    );
    final bytes = await StatementService.generateStatementPDF(
      entries: [
        _entry('e1', LedgerEntryType.rentCharge, 85, DateTime(2026, 9, 1),
            'September rent'),
        // Payments are stored negative, as PaymentService writes them.
        _entry('e2', LedgerEntryType.payment, -85, DateTime(2026, 9, 3),
            'Card payment'),
        // A credit stored negative belongs under Payments.
        _entry('e3', LedgerEntryType.credit, -10, DateTime(2026, 9, 5),
            'Courtesy credit'),
      ],
      tenant: _tenant,
      facility: facility,
      startDate: DateTime(2026, 9, 1),
      endDate: DateTime(2026, 9, 23),
    );
    expect(bytes.length, greaterThan(1000));

    final out = Platform.environment['SFC_PDF_OUT'];
    if (out != null) {
      File('$out/statement.pdf').writeAsBytesSync(bytes);
    }
  });

  test('a logo that cannot be fetched is skipped, not fatal', () async {
    final logo = await PdfLetterhead.loadLogo(
        _facility(logoUrl: 'http://127.0.0.1:9/missing.png'));
    expect(logo, isNull);
  });

  group('account holder block', () {
    test('the mailing address sits directly under the name, then phone, '
        'then the units; no line for a missing email', () async {
      final lines = _textLines(await _statementPdf(
        entries: [
          _entry('e1', LedgerEntryType.rentCharge, 110, DateTime(2026, 9, 1),
              'September rent'),
        ],
        tenant: _mailedTenant,
        facility: _facility(repeat: true),
        unitLabels: statementUnitLabels(_mailedTenant, _facility(repeat: true),
            units: [
              _unit('u7', 'C2-7', area: 'Complex 2'),
              _unit('u6', 'C2-6', area: 'Complex 2'),
            ]),
      ));

      final name = _lineWith(lines, 'Pat Example');
      final street = _lineWith(lines, '12 Example Ave');
      final city = _lineWith(lines, 'Anytown, ND 79401');
      final phone = _lineWith(lines, '(555) 010-0199');
      final units = _lineWith(lines, 'Units: C2-6, C2-7 (Complex 2)');

      // Each line lower than the one before it.
      expect(name.y, greaterThan(street.y));
      expect(street.y, greaterThan(city.y));
      expect(city.y, greaterThan(phone.y));
      expect(phone.y, greaterThan(units.y));
      // And no blank line between the name and the address: an empty email
      // used to take a line of its own here. One line of 10pt text is about
      // 12pt; a blank one would double the gap.
      expect(name.y - street.y, lessThan(16));
      expect(city.y - phone.y, lessThan(16));
      expect(phone.y - units.y, lessThan(16));
    });

    test('holder details never carry an empty line', () {
      expect(
        statementHolderDetails(_mailedTenant, ['C2-6 (Complex 2)']),
        ['12 Example Ave', 'Anytown, ND 79401', '(555) 010-0199', 'Unit: C2-6 (Complex 2)'],
      );
      // No address, no phone, no email, no unit: nothing under the name.
      expect(
        statementHolderDetails(
            _mailedTenant.copyWith(addresses: const [], phone: '  '), const []),
        isEmpty,
      );
      // Email, when there is one, after the phone.
      expect(
        statementHolderDetails(_tenant, ['A-12']),
        ['(555) 987-6543', 'jordan@example.com', 'Unit: A-12'],
      );
    });

    test('unit labels: every unit held, in number order, with the area '
        'named once when it is shared', () {
      final on = _facility(repeat: true);
      final labels = statementUnitLabels(_mailedTenant, on, units: [
        _unit('u10', 'C2-10', area: 'Complex 2'),
        _unit('u6', 'C2-6', area: 'Complex 2'),
        // Marked available: not held, whatever its tenantId says.
        _unit('u9', 'C2-9', area: 'Complex 2', status: UnitStatus.available),
      ]);
      expect(labels, ['C2-6 (Complex 2)', 'C2-10 (Complex 2)']);
      expect(statementUnitsLine(labels), 'Units: C2-6, C2-10 (Complex 2)');

      // Different areas keep their own.
      expect(
        statementUnitsLine(statementUnitLabels(_mailedTenant, on, units: [
          _unit('u17', 'C2-17', area: 'Complex 2'),
          _unit('u7', 'C3-7', area: 'Complex 3'),
        ])),
        'Units: C2-17 (Complex 2), C3-7 (Complex 3)',
      );

      // The setting off: numbers alone, as before.
      expect(
        statementUnitsLine(statementUnitLabels(_mailedTenant, _facility(), units: [
          _unit('u7', 'C2-7', area: 'Complex 2'),
          _unit('u6', 'C2-6', area: 'Complex 2'),
        ])),
        'Units: C2-6, C2-7',
      );

      // No unit list: the tenant's own unit, as the ledger screen falls
      // back to when the read fails.
      expect(statementUnitLabels(_mailedTenant, on), ['C2-6 (Complex 2)']);
      expect(statementUnitsLine(statementUnitLabels(_mailedTenant, _facility())),
          'Unit: C2-6');
      expect(statementUnitsLine(const []), isNull);
    });
  });

  group('remit address', () {
    final entries = [
      _entry('e1', LedgerEntryType.rentCharge, 85, DateTime(2026, 9, 1),
          'September rent'),
    ];

    test('a separate mailing address prints "Mail payments to" once, in the '
        'letterhead', () async {
      final lines = _textLines(await _statementPdf(
        entries: entries,
        tenant: _tenant,
        facility: _facility(mailing: 'PO Box 482\nSpringfield, MO 65801'),
      ));
      expect(_linesWith(lines, 'Mail payments to:'), 1);
      final remit = _lineWith(lines, 'Mail payments to:');
      expect(remit.text, contains('PO Box 482'));
      // In the letterhead, above the account holder.
      expect(remit.y, greaterThan(_lineWith(lines, 'Account Holder:').y));
    });

    test('one address only: the footer says where to mail payments', () async {
      final lines = _textLines(await _statementPdf(
        entries: entries,
        tenant: _tenant,
        facility: _facility(),
      ));
      expect(_linesWith(lines, 'Mail payments to:'), 1);
      expect(_lineWith(lines, 'Mail payments to:').y,
          lessThan(_lineWith(lines, 'Thank you for your business!').y));
    });
  });

  group('balances', () {
    final entries = [
      _entry('e0', LedgerEntryType.rentCharge, 40, DateTime(2026, 7, 1), 'July rent'),
      _entry('p0', LedgerEntryType.payment, -60, DateTime(2026, 7, 2), 'Check #2001'),
      _entry('e1', LedgerEntryType.rentCharge, 40, DateTime(2026, 8, 1), 'August rent'),
      _entry('e2', LedgerEntryType.rentCharge, 40, DateTime(2026, 9, 1), 'September rent'),
    ];

    test('all history: "Current Balance" at the top and again under the table',
        () async {
      final lines = _textLines(await _statementPdf(
        entries: entries,
        tenant: _tenant,
        facility: _facility(),
      ));
      expect(_linesWith(lines, 'Current Balance'), 2);
      expect(_linesWith(lines, 'Balance as of'), 0);
      final bottom = _lineWith(lines, r'Current Balance: $60.00');
      // Under the last table row and above the footer.
      expect(bottom.y, lessThan(_lineWith(lines, 'September rent').y));
      expect(bottom.y, greaterThan(_lineWith(lines, 'Thank you for your business!').y));
      expect(_linesWith(lines, 'Balance forward'), 0);
    });

    test('a period: "Balance as of" the end date, and the balance forward as '
        'the first row, a credit included', () async {
      final lines = _textLines(await _statementPdf(
        entries: entries,
        tenant: _tenant,
        facility: _facility(),
        startDate: DateTime(2026, 8, 1),
        endDate: DateTime(2026, 8, 31),
      ));
      expect(_linesWith(lines, 'Balance as of Aug 31, 2026'), 2);
      expect(_linesWith(lines, 'Current Balance'), 0);
      expect(_lineWith(lines, r'Balance as of Aug 31, 2026: $20.00'), isNotNull);

      final forward = _lineWith(lines, 'Balance forward');
      expect(forward.text, startsWith('Aug 1, 2026 Balance forward'));
      expect(forward.text, contains(r'-$20.00'));
      // First row: above August rent, below the header row.
      expect(forward.y, greaterThan(_lineWith(lines, 'August rent').y));
      expect(forward.y, lessThan(_lineWith(lines, 'Date Description Charges').y));
      // September is outside the period.
      expect(_linesWith(lines, 'September rent'), 0);
      // The statement is dated the day it is printed, not the period's end.
      expect(_lineWith(lines, 'Date: Sep 28, 2026'), isNotNull);
      expect(_lineWith(lines, 'Aug 1, 2026 - Aug 31, 2026'), isNotNull);
    });

    test('a period with nothing carried forward has no balance forward row',
        () async {
      final lines = _textLines(await _statementPdf(
        entries: entries.sublist(2),
        tenant: _tenant,
        facility: _facility(),
        startDate: DateTime(2026, 8, 1),
      ));
      expect(_linesWith(lines, 'Balance forward'), 0);
      // No end date chosen: the period runs to the printed date and the
      // figure is current.
      expect(_lineWith(lines, 'Aug 1, 2026 - Sep 28, 2026'), isNotNull);
      expect(_linesWith(lines, 'Current Balance'), 2);
    });

    test('the balance label follows the end date', () {
      expect(statementBalanceLabel(null), 'Current Balance');
      expect(statementBalanceLabel(DateTime(2026, 9, 23)),
          'Balance as of Sep 23, 2026');
    });
  });

  group('letterhead logo layout', () {
    test('every position and size lays out, with and without a logo', () async {
      for (final position in DocumentLogoPosition.values) {
        for (final height in [
          DocumentLogoLayout.minHeight,
          DocumentLogoLayout.defaultHeight,
          DocumentLogoLayout.maxHeight,
        ]) {
          for (final showName in [true, false]) {
            final facility = _facility(
              mailing: 'PO Box 482\nSpringfield, MO 65801',
              documentLogo: DocumentLogoLayout(
                height: height,
                position: position,
                showName: showName,
              ),
            );
            final withLogo = await _letterheadPdf(facility);
            expect(withLogo, startsWith('%PDF'),
                reason: '$position $height $showName');
            await _letterheadPdf(facility, withLogo: false);
          }
        }
      }
    });

    test('showName off drops the business name only when a logo prints',
        () async {
      final hidden = _facility(
          documentLogo: const DocumentLogoLayout(showName: false));
      final shown = _facility();

      expect(await _letterheadPdf(shown), contains('Keepsake'));
      final noName = await _letterheadPdf(hidden);
      expect(noName, isNot(contains('Keepsake')));
      expect(noName, contains('County'));
      // No logo to carry the name, so the name prints after all.
      expect(await _letterheadPdf(hidden, withLogo: false), contains('Keepsake'));
    });

    test('statements and invoices build with a saved layout', () async {
      final facility = _facility(
        documentLogo: const DocumentLogoLayout(
          height: 140,
          position: DocumentLogoPosition.center,
          showName: false,
        ),
      );
      final bytes = await StatementService.generateStatementPDF(
        entries: [
          _entry('e1', LedgerEntryType.rentCharge, 85, DateTime(2026, 9, 1),
              'September rent'),
        ],
        tenant: _tenant,
        facility: facility,
      );
      expect(bytes.length, greaterThan(1000));
    });
  });
}
