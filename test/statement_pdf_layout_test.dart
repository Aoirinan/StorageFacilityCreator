import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:sfcapp/models/document_logo_layout.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/services/pdf_letterhead.dart';
import 'package:sfcapp/services/statement_service.dart';

FacilityModel _facility({
  String? logoUrl,
  String? mailing,
  String? message,
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

LedgerEntry _entry(String id, LedgerEntryType type, double amount, DateTime at,
        String description) =>
    LedgerEntry(
      id: id,
      tenantId: 't1',
      facilityId: 'f1',
      type: type,
      amount: amount,
      description: description,
      entryDate: at,
      status: LedgerEntryStatus.posted,
      createdAt: at,
      createdBy: 'owner',
    );

void main() {
  test('remit address prefers the mailing address', () {
    expect(PdfLetterhead.remitAddress(_facility()),
        '1200 County Road 45\nSpringfield, MO 65801');
    expect(PdfLetterhead.remitAddress(_facility(mailing: 'PO Box 9')),
        'PO Box 9');
    expect(PdfLetterhead.remitAddress(_facility(mailing: '  ')),
        '1200 County Road 45\nSpringfield, MO 65801');
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
        // A credit stored positive still belongs under Payments.
        _entry('e3', LedgerEntryType.credit, 10, DateTime(2026, 9, 5),
            'Courtesy credit'),
      ],
      tenant: _tenant,
      facility: facility,
      startDate: DateTime(2026, 9, 1),
      endDate: DateTime(2026, 9, 23),
      balanceForward: 0,
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
