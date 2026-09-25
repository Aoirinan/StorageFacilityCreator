import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/address_model.dart';
import 'package:sfcapp/utils/print_documents.dart';

String invoice({
  String facilityName = 'Caprock Storage',
  String? facilityAddress = '100 Main St, Lubbock, TX 79401',
  String? facilityMailingAddress,
  String? facilityPhone = '806-555-0100',
  String? facilityEmail = 'office@example.com',
  String? facilityLogoUrl,
  String tenantName = 'Jane Doe',
  String? tenantAddress,
  String? tenantPhone,
  String? tenantEmail,
  String? unitNumber,
  String? notes,
  List<({String description, String amount})> lineItems = const [
    (description: 'Rent - Unit A12', amount: r'$95.00'),
  ],
}) {
  return buildInvoiceHtml(
    facilityName: facilityName,
    facilityAddress: facilityAddress,
    facilityMailingAddress: facilityMailingAddress,
    facilityPhone: facilityPhone,
    facilityEmail: facilityEmail,
    facilityLogoUrl: facilityLogoUrl,
    tenantName: tenantName,
    tenantAddress: tenantAddress,
    tenantPhone: tenantPhone,
    tenantEmail: tenantEmail,
    unitNumber: unitNumber,
    invoiceNumber: 'INV-0001',
    issueDateFormatted: 'Sep 1, 2026',
    dueDateFormatted: 'Sep 5, 2026',
    lineItems: lineItems,
    subtotalFormatted: r'$95.00',
    totalFormatted: r'$95.00',
    balanceFormatted: r'$95.00',
    notes: notes,
  );
}

Address address({
  AddressType type = AddressType.mailing,
  bool isPrimary = false,
  String street1 = '1 Elm St',
  String? street2,
  String city = 'Lubbock',
}) =>
    Address(
      id: street1,
      type: type,
      street1: street1,
      street2: street2,
      city: city,
      state: 'TX',
      zipCode: '79401',
      isPrimary: isPrimary,
      createdAt: DateTime(2026),
    );

void main() {
  const logo =
      'https://firebasestorage.googleapis.com/v0/b/x/o/logo.png?alt=media&token=abc';

  group('invoice letterhead: logo', () {
    test('an http(s) logo is an <img> above the facility name', () {
      final html = invoice(facilityLogoUrl: logo);
      expect(
        html,
        contains('<img class="logo" src="'
            'https://firebasestorage.googleapis.com/v0/b/x/o/logo.png?alt=media&amp;token=abc"'),
      );
      expect(html.indexOf('<img class="logo"'),
          lessThan(html.indexOf('<div class="facility-name">')));
      // Sized like the letterhead asks: bounded both ways, never stretched.
      expect(html, contains('max-height: 64px'));
      expect(html, contains('max-width: 220px'));
      expect(html, contains('object-fit: contain'));
    });

    test('no logo set prints no <img>', () {
      expect(invoice(), isNot(contains('<img')));
      expect(invoice(facilityLogoUrl: '   '), isNot(contains('<img')));
    });

    test('only http(s) logo URLs reach the page', () {
      for (final bad in [
        'javascript:alert(1)',
        'data:image/png;base64,AAAA',
        'file:///etc/passwd',
        '/relative/logo.png',
        'https//missing-colon',
      ]) {
        expect(invoice(facilityLogoUrl: bad), isNot(contains('<img')),
            reason: bad);
      }
      expect(safeLogoUrl('HTTP://example.com/a.png'), 'HTTP://example.com/a.png');
      expect(safeLogoUrl(' https://example.com/a.png '),
          'https://example.com/a.png');
    });

    test('a quote in the logo URL cannot break out of the src attribute', () {
      final html =
          invoice(facilityLogoUrl: 'https://example.com/a.png" onerror="alert(1)');
      expect(html, isNot(contains('" onerror="')));
      expect(html, contains('&quot; onerror=&quot;alert(1)'));
    });
  });

  group('invoice letterhead: mailing address', () {
    test('a mailing address prints as "Mail payments to" under the physical one',
        () {
      final html = invoice(facilityMailingAddress: 'PO Box 42, Lubbock, TX 79408');
      expect(
        html,
        contains('<span class="muted">Mail payments to:</span> '
            'PO Box 42, Lubbock, TX 79408'),
      );
      expect(html.indexOf('100 Main St'), lessThan(html.indexOf('Mail payments to:')));
    });

    test('no mailing address, no "Mail payments to" line', () {
      expect(invoice(), isNot(contains('Mail payments to')));
      expect(invoice(facilityMailingAddress: '  '), isNot(contains('Mail payments to')));
    });

    test('a mailing address equal to the physical one is not printed twice', () {
      final html = invoice(
        facilityAddress: '100 Main St, Lubbock, TX 79401',
        facilityMailingAddress: ' 100 Main St, Lubbock, TX 79401 ',
      );
      expect(html, isNot(contains('Mail payments to')));
    });

    test('a multi-line address keeps its lines', () {
      final html = invoice(facilityMailingAddress: 'PO Box 42\nLubbock, TX 79408');
      expect(html, contains('PO Box 42<br>Lubbock, TX 79408'));
    });
  });

  group('invoice escaping', () {
    test('every value is HTML-escaped', () {
      final html = invoice(
        facilityName: 'Tom & Jerry <Storage>',
        facilityMailingAddress: '<script>alert(1)</script>',
        tenantName: "O'Brien <b>",
        tenantEmail: 'a&b@example.com',
        unitNumber: '<A1>',
        notes: 'Pay "soon"',
        lineItems: const [(description: '<i>Rent</i>', amount: r'$1')],
      );
      expect(html, isNot(contains('<script>')));
      expect(html, isNot(contains('<b>')));
      expect(html, isNot(contains('<i>Rent')));
      expect(html, contains('Tom &amp; Jerry &lt;Storage&gt;'));
      expect(html, contains('&lt;script&gt;alert(1)&lt;/script&gt;'));
      expect(html, contains('O&#39;Brien &lt;b&gt;'));
      expect(html, contains('a&amp;b@example.com'));
      expect(html, contains('&lt;A1&gt;'));
      expect(html, contains('Pay &quot;soon&quot;'));
      expect(html, contains('&lt;i&gt;Rent&lt;/i&gt;'));
    });
  });

  group('invoice bill-to', () {
    test('prints name, unit, address, phone and email when present', () {
      final html = invoice(
        tenantName: 'Jane Doe',
        unitNumber: 'A12',
        tenantAddress: '1 Elm St\nLubbock, TX 79401',
        tenantPhone: '806-555-0199',
        tenantEmail: 'jane@example.com',
      );
      final billTo = html.substring(
          html.indexOf('<div class="bill-to">'), html.indexOf('<table>'));
      expect(billTo, contains('<div>Jane Doe</div>'));
      expect(billTo, contains('<span class="muted">Unit</span> A12'));
      expect(billTo, contains('1 Elm St<br>Lubbock, TX 79401'));
      expect(billTo, contains('806-555-0199'));
      expect(billTo, contains('jane@example.com'));
    });

    test('empty tenant details leave no blank lines behind', () {
      final html = invoice(
        tenantName: 'Tenant',
        unitNumber: '',
        tenantPhone: '',
        tenantEmail: '',
      );
      final billTo = html.substring(
          html.indexOf('<div class="bill-to">'), html.indexOf('<table>'));
      expect(billTo, contains('<div>Tenant</div>'));
      expect(billTo, isNot(contains('Unit')));
      expect(RegExp('<div>').allMatches(billTo).length, 1);
    });
  });

  group('tenantPrintAddress', () {
    test('formats the address instead of printing "Instance of \'Address\'"', () {
      final text = tenantPrintAddress([address(street2: 'Apt 4')]);
      expect(text, '1 Elm St\nApt 4\nLubbock, TX 79401');
      expect(text, isNot(contains('Instance of')));
    });

    test('prefers the primary address, then billing, then mailing', () {
      expect(
        tenantPrintAddress([
          address(street1: 'Other', type: AddressType.other),
          address(street1: 'Mail', type: AddressType.mailing),
          address(street1: 'Bill', type: AddressType.billing),
        ]),
        startsWith('Bill'),
      );
      expect(
        tenantPrintAddress([
          address(street1: 'Bill', type: AddressType.billing),
          address(street1: 'Primary', type: AddressType.alternate, isPrimary: true),
        ]),
        startsWith('Primary'),
      );
      expect(
        tenantPrintAddress([
          address(street1: 'Other', type: AddressType.other),
          address(street1: 'Mail', type: AddressType.mailing),
        ]),
        startsWith('Mail'),
      );
    });

    test('no addresses, or only empty ones, gives null', () {
      expect(tenantPrintAddress(const []), isNull);
      expect(tenantPrintAddress([address(street1: '', city: '')]), isNull);
    });
  });

  group('payment receipt letterhead', () {
    test('carries the facility logo, name, address and mailing address', () {
      final html = buildPaymentReceiptHtml(
        tenantName: 'Jane Doe',
        amountFormatted: r'$95.00',
        dateFormatted: '2026-09-25 10:00',
        businessName: 'Caprock Storage',
        businessAddress: '100 Main St',
        businessMailingAddress: 'PO Box 42',
        logoUrl: logo,
      );
      expect(html, contains('<img class="logo"'));
      expect(html, contains('<div class="facility-name">Caprock Storage</div>'));
      expect(html, contains('100 Main St'));
      expect(html, contains('Mail payments to:</span> PO Box 42'));
      expect(html, isNot(contains('Storage Facility Creator')));
    });

    test('without facility details it still prints under the platform name', () {
      final html = buildPaymentReceiptHtml(
        tenantName: 'Jane <Doe>',
        amountFormatted: r'$95.00',
        dateFormatted: '2026-09-25 10:00',
        logoUrl: 'javascript:alert(1)',
      );
      expect(html, contains('Storage Facility Creator'));
      expect(html, isNot(contains('<img')));
      expect(html, contains('Jane &lt;Doe&gt;'));
    });
  });
}
