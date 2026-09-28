import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/address_model.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/invoice_model.dart';
import 'package:sfcapp/models/lien_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/services/invoice_service.dart';
import 'package:sfcapp/services/lien_service.dart';
import 'package:sfcapp/utils/print_documents.dart';

Address _address({
  String street1 = '',
  String? street2,
  String city = '',
  String state = '',
  String zipCode = '',
  String? country,
  AddressType type = AddressType.mailing,
  bool isPrimary = false,
}) =>
    Address(
      id: 'a-$street1',
      type: type,
      street1: street1,
      street2: street2,
      city: city,
      state: state,
      zipCode: zipCode,
      country: country,
      isPrimary: isPrimary,
      createdAt: DateTime(2026),
    );

/// The text a PDF draws, in order, one entry per string operand of a
/// Tj or TJ operator (the pdf package draws a line word by word). Streams are
/// inflated first, so compressed documents can be read too.
List<String> _pdfWords(Uint8List bytes) {
  final raw = latin1.decode(bytes);
  final content = StringBuffer();
  final streamRe = RegExp(r'stream\r?\n');
  var at = 0;
  while (true) {
    final m = streamRe.allMatches(raw, at).firstOrNull;
    if (m == null) break;
    final end = raw.indexOf('endstream', m.end);
    if (end < 0) break;
    final data = latin1.encode(raw.substring(m.end, end));
    try {
      content.write(latin1.decode(ZLibDecoder().convert(data)));
    } catch (_) {
      content.write(raw.substring(m.end, end));
    }
    content.write('\n');
    at = end;
  }
  // A string operand: (...) with backslash escapes.
  const str = r'\((?:\\.|[^\\)])*\)';
  String unescape(String operand) => operand
      .substring(1, operand.length - 1)
      .replaceAllMapped(RegExp(r'\\(.)'), (x) => x.group(1)!);
  final op = RegExp('($str)' r'\s*Tj|\[((?:' '$str' r'|[^\]])*)\]\s*TJ');
  final words = <String>[];
  for (final m in op.allMatches(content.toString())) {
    final single = m.group(1);
    words.add(single != null
        ? unescape(single)
        : RegExp(str)
            .allMatches(m.group(2)!)
            .map((s) => unescape(s.group(0)!))
            .join());
  }
  return words;
}

FacilityModel _facility() => FacilityModel(
      id: 'f1',
      name: 'Test Storage',
      ownerUid: 'owner',
      createdAt: DateTime(2026, 1, 1),
      address: '100 Main St\nLubbock, TX 79401',
      phone: '806-555-0100',
      email: 'office@example.com',
    );

TenantModel _tenant(List<Address> addresses) => TenantModel(
      id: 't1',
      facilityId: 'f1',
      name: 'Jordan Tenant',
      email: 'jordan@example.com',
      phone: '(555) 987-6543',
      unitNumber: 'A-12',
      monthlyRate: 85,
      createdAt: DateTime(2026, 8, 1),
      addresses: addresses,
    );

final _invoice = InvoiceModel(
  id: 'i1',
  tenantId: 't1',
  facilityId: 'f1',
  invoiceNumber: 'INV-2026-001',
  status: InvoiceStatus.draft,
  issueDate: DateTime(2026, 9, 1),
  dueDate: DateTime(2026, 9, 15),
  subtotal: 100,
  total: 100,
  balance: 100,
  lineItems: const [],
  ledgerEntryIds: const [],
  paymentIds: const [],
  createdAt: DateTime(2026, 9, 1),
  createdBy: 'owner',
);

final _lien = LienModel(
  id: 'l1',
  facilityId: 'f1',
  tenantId: 't1',
  unitId: 'u1',
  contractId: 'c1',
  currentStage: LienStage.noticeSent,
  status: LienStatus.active,
  totalAmount: 300,
  principalAmount: 250,
  lateFees: 50,
  createdAt: DateTime(2026, 9, 1),
  createdBy: 'owner',
);

final _unit = UnitModel(
  id: 'u1',
  facilityId: 'f1',
  unitNumber: 'A-12',
  unitType: 'standard',
  status: UnitStatus.occupied,
  tenantId: 't1',
  monthlyRate: 85,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
  createdBy: 'owner',
);

/// No empty lines, lone commas, double spaces or stray separators at either
/// end of a line.
void _expectTidy(String text) {
  for (final line in text.split('\n')) {
    expect(line.trim(), isNotEmpty, reason: 'empty line in "$text"');
    expect(line, isNot(contains('  ')), reason: 'double space in "$text"');
    expect(line, line.trim(), reason: 'untrimmed line in "$text"');
    expect(line.startsWith(','), isFalse, reason: 'leading comma in "$text"');
    expect(line.endsWith(','), isFalse, reason: 'trailing comma in "$text"');
    expect(line, isNot(contains(', ,')), reason: 'double comma in "$text"');
  }
}

void main() {
  group('Address.formattedAddress', () {
    final cases = <String, (Address, String)>{
      'full': (
        _address(
          street1: '1 Elm St',
          street2: 'Apt 4',
          city: 'Lubbock',
          state: 'TX',
          zipCode: '79401',
        ),
        '1 Elm St\nApt 4\nLubbock, TX 79401',
      ),
      'street only': (_address(street1: '1 Elm St'), '1 Elm St'),
      'street and street2 only': (
        _address(street1: '1 Elm St', street2: 'Apt 4'),
        '1 Elm St\nApt 4',
      ),
      'street and city': (
        _address(street1: '1 Elm St', city: 'Lubbock'),
        '1 Elm St\nLubbock',
      ),
      'street, city and state': (
        _address(street1: '1 Elm St', city: 'Lubbock', state: 'TX'),
        '1 Elm St\nLubbock, TX',
      ),
      'street, city and zip': (
        _address(street1: '1 Elm St', city: 'Lubbock', zipCode: '79401'),
        '1 Elm St\nLubbock 79401',
      ),
      'street, state and zip': (
        _address(street1: '1 Elm St', state: 'TX', zipCode: '79401'),
        '1 Elm St\nTX 79401',
      ),
      'PO box with city, state and zip': (
        _address(
          street1: 'PO Box 482',
          city: 'Springfield',
          state: 'MO',
          zipCode: '65801',
        ),
        'PO Box 482\nSpringfield, MO 65801',
      ),
      'blank street2 and padded parts': (
        _address(
          street1: '  1  Elm   St ',
          street2: '   ',
          city: ' Lubbock ',
          state: ' TX',
          zipCode: '79401 ',
        ),
        '1 Elm St\nLubbock, TX 79401',
      ),
      'US country is left off': (
        _address(
          street1: '1 Elm St',
          city: 'Lubbock',
          state: 'TX',
          zipCode: '79401',
          country: 'US',
        ),
        '1 Elm St\nLubbock, TX 79401',
      ),
      'other US spellings are left off': (
        _address(street1: '1 Elm St', country: 'United States'),
        '1 Elm St',
      ),
      'non-US country prints': (
        _address(
          street1: '10 King St W',
          city: 'Toronto',
          state: 'ON',
          zipCode: 'M5H 1A1',
          country: 'Canada',
        ),
        '10 King St W\nToronto, ON M5H 1A1\nCanada',
      ),
    };

    cases.forEach((name, c) {
      test(name, () {
        final (address, expected) = c;
        expect(address.formattedAddress, expected);
        _expectTidy(address.formattedAddress);
        expect(address.addressLines, expected.split('\n'));
      });
    });

    test('an empty address has no lines', () {
      final empty = _address();
      expect(empty.addressLines, isEmpty);
      expect(empty.formattedAddress, '');
      expect(empty.singleLineAddress, '');
      expect(empty.localityLine, '');
      expect(_address(country: 'US').addressLines, isEmpty);
    });

    test('singleLineAddress joins only the parts present', () {
      expect(_address(street1: '1 Elm St').singleLineAddress, '1 Elm St');
      expect(
        _address(
          street1: '1 Elm St',
          street2: 'Apt 4',
          city: 'Lubbock',
          state: 'TX',
          zipCode: '79401',
        ).singleLineAddress,
        '1 Elm St, Apt 4, Lubbock, TX 79401',
      );
    });
  });

  group('printed invoice (HTML)', () {
    test('a street-only address prints one line, no stray comma', () {
      final address = tenantPrintAddress([_address(street1: '1 Elm St')]);
      expect(address, '1 Elm St');
      final html = buildInvoiceHtml(
        facilityName: 'Test Storage',
        tenantName: 'Jordan Tenant',
        tenantAddress: address,
        invoiceNumber: 'INV-0001',
        issueDateFormatted: 'Sep 1, 2026',
        dueDateFormatted: 'Sep 5, 2026',
        lineItems: const [],
        subtotalFormatted: r'$0.00',
        totalFormatted: r'$0.00',
        balanceFormatted: r'$0.00',
      );
      expect(html, contains('<div>1 Elm St</div>'));
      expect(html, isNot(contains('1 Elm St<br>')));
      expect(html, isNot(contains('<br>,')));
      expect(html, isNot(contains('Instance of')));
    });
  });

  group('invoice PDF', () {
    test('a street-only address prints no stray comma line', () async {
      final bytes = await InvoiceService.generateInvoicePDF(
        invoice: _invoice,
        tenant: _tenant([_address(street1: '1 Elm St')]),
        facility: _facility(),
      );
      final words = _pdfWords(bytes);
      // The Bill To block: name, email, phone, then the address.
      final start = words.indexOf('(555)');
      expect(start, greaterThanOrEqualTo(0), reason: words.join(' '));
      expect(words.sublist(start, start + 5),
          ['(555)', '987-6543', '1', 'Elm', 'St']);
      expect(words, isNot(contains(',')));
      expect(words, isNot(contains('Instance')));
    });

    test('a full address prints city, state and zip', () async {
      final bytes = await InvoiceService.generateInvoicePDF(
        invoice: _invoice,
        tenant: _tenant([
          _address(
            street1: '1 Elm St',
            city: 'Lubbock',
            state: 'TX',
            zipCode: '79401',
            country: 'US',
          ),
        ]),
        facility: _facility(),
      );
      final words = _pdfWords(bytes);
      final start = words.indexOf('987-6543');
      expect(words.sublist(start + 1, start + 7),
          ['1', 'Elm', 'St', 'Lubbock,', 'TX', '79401']);
      expect(words, isNot(contains('US')));
    });
  });

  group('lien notice PDF', () {
    test('prints the formatted address, not "Instance of \'Address\'"',
        () async {
      final bytes = await LienService.generateLienNoticePDFForTest(
        lien: _lien,
        tenant: _tenant([
          _address(
            street1: '1 Elm St',
            street2: 'Apt 4',
            city: 'Lubbock',
            state: 'TX',
            zipCode: '79401',
            country: 'US',
          ),
          _address(street1: 'PO Box 9', type: AddressType.alternate),
        ]),
        facility: _facility(),
        unit: _unit,
      );
      final words = _pdfWords(bytes);
      expect(words, isNot(contains('Instance')));
      expect(words, isNot(contains("'Address'")));
      final start = words.indexOf('Tenant');
      expect(words.sublist(start + 1, start + 12), [
        '1', 'Elm', 'St', 'Apt', '4', 'Lubbock,', 'TX', '79401', //
        'PO', 'Box', '9',
      ]);
      expect(words, isNot(contains(',')));
    });

    test('a tenant with no address prints none', () async {
      final bytes = await LienService.generateLienNoticePDFForTest(
        lien: _lien,
        tenant: _tenant(const []),
        facility: _facility(),
        unit: _unit,
      );
      final words = _pdfWords(bytes);
      final start = words.indexOf('Tenant');
      expect(words[start + 1], 'NOTICE');
    });
  });
}
