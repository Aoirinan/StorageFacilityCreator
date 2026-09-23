import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/services/pdf_letterhead.dart';
import 'package:sfcapp/services/statement_service.dart';

FacilityModel _facility({String? logoUrl, String? mailing, String? message}) =>
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
    );

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
}
