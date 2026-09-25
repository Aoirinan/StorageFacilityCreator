import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/address_model.dart';
import 'package:sfcapp/models/document_logo_layout.dart';
import 'package:sfcapp/utils/print_documents.dart';

String invoice({
  String facilityName = 'Caprock Storage',
  String? facilityAddress = '100 Main St, Lubbock, TX 79401',
  String? facilityMailingAddress,
  String? facilityPhone = '806-555-0100',
  String? facilityEmail = 'office@example.com',
  String? facilityLogoUrl,
  DocumentLogoLayout logoLayout = DocumentLogoLayout.defaults,
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
    logoLayout: logoLayout,
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
    test('an http(s) logo is an <img> before the facility name', () {
      final html = invoice(facilityLogoUrl: logo);
      expect(
        html,
        contains('<img class="logo" src="'
            'https://firebasestorage.googleapis.com/v0/b/x/o/logo.png?alt=media&amp;token=abc"'),
      );
      expect(html.indexOf('<img class="logo"'),
          lessThan(html.indexOf('<div class="facility-name">')));
      // With no layout saved it matches the statement PDF: 64pt tall, left
      // of the details, width bounded and never stretched.
      expect(html, contains('<div class="letterhead logo-left">'));
      expect(html, contains('style="height: 64pt; max-width: min(180pt, 100%)"'));
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
  group('letterhead logo layout', () {
    String letterhead(DocumentLogoLayout layout,
            {String? logoUrl = logo, String name = 'Caprock Storage'}) =>
        buildLetterheadHtml(
          facilityName: name,
          logoUrl: logoUrl,
          address: '100 Main St',
          mailingAddress: 'PO Box 42',
          layout: layout,
        );

    test('the height and max width follow the slider and position', () {
      for (final (layout, style) in [
        (
          const DocumentLogoLayout(height: 40),
          'height: 40pt; max-width: min(180pt, 100%)'
        ),
        (
          const DocumentLogoLayout(
              height: 160, position: DocumentLogoPosition.above),
          'width: 260pt; max-width: 100%; max-height: 160pt'
        ),
        (
          const DocumentLogoLayout(
              height: 96.5, position: DocumentLogoPosition.center),
          'width: 400pt; max-width: 100%; max-height: 96.5pt'
        ),
      ]) {
        expect(letterhead(layout), contains('style="$style"'),
            reason: '$layout');
      }
    });

    test('the logo carries its fit limits for the exact resize at print time',
        () {
      final html = letterhead(const DocumentLogoLayout(
          height: 120, position: DocumentLogoPosition.above));
      expect(html, contains('data-fit-width="260.0" data-fit-height="120.0"'));
    });

    test('fitLogoBox: largest size in proportion inside the limits', () {
      // A wide logo is held by the width limit...
      expect(
          fitLogoBox(
              naturalWidth: 400,
              naturalHeight: 100,
              maxWidth: 180,
              maxHeight: 120),
          (width: 180.0, height: 45.0));
      // ...a tall one by the height, and a small one is scaled up.
      expect(
          fitLogoBox(
              naturalWidth: 50, naturalHeight: 50, maxWidth: 180, maxHeight: 64),
          (width: 64.0, height: 64.0));
      // Not loaded or broken: leave the markup's sizing alone.
      expect(
          fitLogoBox(
              naturalWidth: 0, naturalHeight: 0, maxWidth: 180, maxHeight: 64),
          isNull);
    });

    test('left: the logo sits inside the letterhead, beside the details', () {
      final html = letterhead(DocumentLogoLayout.defaults);
      expect(html, startsWith('<div class="letterhead logo-left">'));
      expect(html, isNot(contains('logo-banner')));
      expect(html.indexOf('<img'), lessThan(html.indexOf('class="details"')));
    });

    test('above: the logo is its own line over the details', () {
      final html = letterhead(
          const DocumentLogoLayout(position: DocumentLogoPosition.above));
      expect(html, startsWith('<div class="letterhead logo-above">'));
      expect(html, isNot(contains('logo-banner')));
      expect(html.indexOf('<img'), lessThan(html.indexOf('class="details"')));
    });

    test('center: the logo is a banner ahead of the letterhead block', () {
      final parts = buildLetterheadHtmlParts(
        facilityName: 'Caprock Storage',
        logoUrl: logo,
        layout: const DocumentLogoLayout(position: DocumentLogoPosition.center),
      );
      expect(parts.banner, startsWith('<div class="logo-banner"><img class="logo"'));
      expect(parts.block, isNot(contains('<img')));
      expect(parts.block, contains('<div class="letterhead logo-center">'));

      // On the invoice the banner spans the page, above the row that holds
      // the details and the invoice number.
      final html = invoice(
        facilityLogoUrl: logo,
        logoLayout:
            const DocumentLogoLayout(position: DocumentLogoPosition.center),
      );
      expect(html.indexOf('<div class="logo-banner">'),
          lessThan(html.indexOf('<div class="top">')));
      expect(html, contains('.logo-banner .logo { margin: 0 auto;'));
    });

    test('center without a logo prints no empty banner', () {
      final parts = buildLetterheadHtmlParts(
        facilityName: 'Caprock Storage',
        layout: const DocumentLogoLayout(position: DocumentLogoPosition.center),
      );
      expect(parts.banner, isEmpty);
      expect(parts.block, contains('Caprock Storage'));
    });

    test('showName off drops the name text but keeps it as the alt text', () {
      final html = letterhead(const DocumentLogoLayout(showName: false));
      expect(html, isNot(contains('facility-name')));
      expect(html, contains('alt="Caprock Storage"'));
      // Addresses still print.
      expect(html, contains('100 Main St'));
      expect(html, contains('Mail payments to:'));
    });

    test('showName off still prints the name when there is no usable logo', () {
      for (final url in [null, '', 'javascript:alert(1)']) {
        final html = letterhead(const DocumentLogoLayout(showName: false),
            logoUrl: url);
        expect(html, contains('<div class="facility-name">Caprock Storage</div>'),
            reason: '$url');
      }
    });

    test('the name is escaped in the alt text too', () {
      final html = letterhead(const DocumentLogoLayout(showName: false),
          name: 'A "B" <C>');
      expect(html, contains('alt="A &quot;B&quot; &lt;C&gt;"'));
    });

    test('the receipt uses the same layout', () {
      final html = buildPaymentReceiptHtml(
        tenantName: 'Jane Doe',
        amountFormatted: r'$95.00',
        dateFormatted: '2026-09-25 10:00',
        businessName: 'Caprock Storage',
        logoUrl: logo,
        logoLayout: const DocumentLogoLayout(
          height: 120,
          position: DocumentLogoPosition.center,
          showName: false,
        ),
      );
      expect(html, contains('<div class="logo-banner"><img class="logo"'));
      expect(html, contains('height: 120pt'));
      expect(html, isNot(contains('<div class="facility-name">')));
      expect(html.indexOf('logo-banner'),
          lessThan(html.indexOf('<h1>Payment receipt</h1>')));
    });
  });
}
