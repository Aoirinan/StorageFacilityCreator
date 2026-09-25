import 'package:sfcapp/models/address_model.dart';

/// The HTML behind the web "Print" buttons (invoice, payment receipt), kept
/// apart from print_util_web.dart so it can be built and tested without a
/// browser. print_util_web.dart only renders these strings in a frame and
/// opens the print dialog.
///
/// Every value that reaches the markup goes through [escapeHtml]; the logo URL
/// additionally has to be http(s) (see [safeLogoUrl]).

String escapeHtml(String s) {
  return s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
}

/// Escapes [s] and keeps its line breaks, for multi-line addresses.
String _escapeLines(String s) =>
    s.trim().split(RegExp(r'\r?\n')).map((l) => escapeHtml(l.trim())).join('<br>');

String? _clean(String? s) {
  final t = s?.trim();
  return (t == null || t.isEmpty) ? null : t;
}

/// The logo URL if it is an absolute http(s) URL, otherwise null — a
/// `javascript:` or `data:` value from a facility doc never reaches an <img>.
String? safeLogoUrl(String? url) {
  final t = _clean(url);
  if (t == null) return null;
  final uri = Uri.tryParse(t);
  if (uri == null || !uri.hasAuthority) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  return t;
}

/// The tenant address to print on a bill: the primary one, else a billing or
/// mailing address, else the first. Null when the tenant has none that says
/// anything.
///
/// `Address` has no toString, so printing `addresses.first.toString()` put
/// "Instance of 'Address'" on the invoice; this uses [Address.formattedAddress].
String? tenantPrintAddress(List<Address> addresses) {
  final usable = addresses
      .where((a) => a.street1.trim().isNotEmpty || a.city.trim().isNotEmpty)
      .toList();
  if (usable.isEmpty) return null;
  Address? pick(bool Function(Address) test) {
    for (final a in usable) {
      if (test(a)) return a;
    }
    return null;
  }

  final chosen = pick((a) => a.isPrimary) ??
      pick((a) => a.type == AddressType.billing) ??
      pick((a) => a.type == AddressType.mailing) ??
      usable.first;
  return _clean(chosen.formattedAddress);
}

/// The facility's letterhead as it appears on tenant-facing PDFs
/// (lib/services/pdf_letterhead.dart): logo, business name, physical address,
/// then the mailing address when it is set and different, phone and email.
String buildLetterheadHtml({
  required String facilityName,
  String? logoUrl,
  String? address,
  String? mailingAddress,
  String? phone,
  String? email,
}) {
  final logo = safeLogoUrl(logoUrl);
  final physical = _clean(address);
  final mailing = _clean(mailingAddress);
  // Same rule as PdfLetterhead: a mailing address that repeats the physical
  // one is not printed twice.
  final showMailing = mailing != null && mailing != physical;
  final parts = <String>[
    if (logo != null)
      '<img class="logo" src="${escapeHtml(logo)}" alt="${escapeHtml(facilityName)} logo">',
    '<div class="facility-name">${escapeHtml(facilityName)}</div>',
    if (physical != null) '<div>${_escapeLines(physical)}</div>',
    if (showMailing)
      '<div class="mailing"><span class="muted">Mail payments to:</span> ${_escapeLines(mailing)}</div>',
    if (_clean(phone) != null) '<div>${escapeHtml(_clean(phone)!)}</div>',
    if (_clean(email) != null) '<div>${escapeHtml(_clean(email)!)}</div>',
  ];
  return '<div class="letterhead">\n        ${parts.join('\n        ')}\n      </div>';
}

/// Styles shared by every printed document's letterhead.
const String _letterheadCss = '''
    .letterhead .logo {
      display: block;
      max-height: 64px;
      max-width: 220px;
      width: auto;
      height: auto;
      object-fit: contain;
      margin-bottom: 8px;
    }
    .facility-name { font-size: 20px; font-weight: 700; margin-bottom: 2px; }
    .mailing { margin-top: 2px; }
    .muted { color: #6b7280; }
''';

String buildPaymentReceiptHtml({
  required String tenantName,
  required String amountFormatted,
  required String dateFormatted,
  String? transactionId,
  String? businessName,
  String? businessAddress,
  String? businessMailingAddress,
  String? businessPhone,
  String? businessEmail,
  String? logoUrl,
}) {
  final org = _clean(businessName) ?? 'Storage Facility Creator';
  final tenant = escapeHtml(tenantName);
  final amount = escapeHtml(amountFormatted);
  final when = escapeHtml(dateFormatted);
  final txn = _clean(transactionId);

  final txnBlock = txn == null
      ? ''
      : '''
      <div class="row">
        <span class="label">Transaction ID</span>
        <span class="value mono">${escapeHtml(txn)}</span>
      </div>''';

  final letterhead = buildLetterheadHtml(
    facilityName: org,
    logoUrl: logoUrl,
    address: businessAddress,
    mailingAddress: businessMailingAddress,
    phone: businessPhone,
    email: businessEmail,
  );

  return '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Payment receipt</title>
  <style>
    @page { margin: 16mm; size: portrait; }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      padding: 0;
      font-family: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
      font-size: 14px;
      line-height: 1.45;
      color: #111827;
      background: #fff;
    }
    .wrap {
      max-width: 420px;
      margin: 0 auto;
    }
    .letterhead { font-size: 12px; margin-bottom: 20px; }
    .letterhead .facility-name { font-size: 16px; }
$_letterheadCss
    h1 {
      font-size: 22px;
      font-weight: 700;
      margin: 0 0 4px 0;
    }
    .status {
      color: #059669;
      font-weight: 600;
      margin: 0 0 20px 0;
      font-size: 15px;
    }
    .card {
      border: 1px solid #e5e7eb;
      border-radius: 8px;
      padding: 16px 18px;
      margin-bottom: 16px;
    }
    .row {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 12px;
      padding: 8px 0;
      border-bottom: 1px solid #f3f4f6;
    }
    .row:last-child { border-bottom: none; }
    .label { color: #6b7280; flex-shrink: 0; min-width: 110px; }
    .value { font-weight: 600; text-align: right; word-break: break-word; }
    .amount { font-size: 20px; font-weight: 700; }
    .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; font-size: 12px; font-weight: 500; }
    .note {
      font-size: 12px;
      color: #6b7280;
      margin-top: 8px;
    }
  </style>
</head>
<body>
  <div class="wrap">
    $letterhead
    <h1>Payment receipt</h1>
    <p class="status">Payment received</p>
    <div class="card">
      <div class="row">
        <span class="label">Tenant</span>
        <span class="value">$tenant</span>
      </div>
      <div class="row">
        <span class="label">Amount</span>
        <span class="value amount">$amount</span>
      </div>
      <div class="row">
        <span class="label">Date</span>
        <span class="value">$when</span>
      </div>
      $txnBlock
    </div>
    <p class="note">This receipt is for your records. The payment is saved in your account.</p>
  </div>
</body>
</html>
''';
}

String buildInvoiceHtml({
  required String facilityName,
  String? facilityAddress,
  String? facilityMailingAddress,
  String? facilityPhone,
  String? facilityEmail,
  String? facilityLogoUrl,
  required String tenantName,
  String? tenantAddress,
  String? tenantPhone,
  String? tenantEmail,
  String? unitNumber,
  required String invoiceNumber,
  required String issueDateFormatted,
  required String dueDateFormatted,
  required List<({String description, String amount})> lineItems,
  required String subtotalFormatted,
  String? taxFormatted,
  required String totalFormatted,
  required String balanceFormatted,
  String? notes,
  String? statusLabel,
}) {
  String line(String? label, String? value) {
    final v = _clean(value);
    if (v == null) return '';
    final text = _escapeLines(v);
    return label == null
        ? '<div>$text</div>'
        : '<div><span class="muted">${escapeHtml(label)}</span> $text</div>';
  }

  final rows = lineItems
      .map((item) => '''
      <tr>
        <td>${escapeHtml(item.description)}</td>
        <td class="num">${escapeHtml(item.amount)}</td>
      </tr>''')
      .join();

  final taxRow = (taxFormatted == null || taxFormatted.isEmpty)
      ? ''
      : '''
      <tr>
        <td class="label">Tax</td>
        <td class="num">${escapeHtml(taxFormatted)}</td>
      </tr>''';

  final notesBlock = (notes == null || notes.trim().isEmpty)
      ? ''
      : '<div class="notes"><span class="muted">Notes</span><br>${_escapeLines(notes)}</div>';

  final letterhead = buildLetterheadHtml(
    facilityName: facilityName,
    logoUrl: facilityLogoUrl,
    address: facilityAddress,
    mailingAddress: facilityMailingAddress,
    phone: facilityPhone,
    email: facilityEmail,
  );

  return '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Invoice ${escapeHtml(invoiceNumber)}</title>
  <style>
    @page { margin: 16mm; size: portrait; }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
      font-size: 13px;
      line-height: 1.45;
      color: #111827;
      background: #fff;
    }
    .wrap { max-width: 640px; margin: 0 auto; }
    .top { display: flex; justify-content: space-between; gap: 24px; align-items: flex-start; }
    .letterhead { min-width: 0; }
$_letterheadCss
    h1 { font-size: 20px; font-weight: 700; margin: 0 0 4px 0; text-align: right; }
    .meta { text-align: right; flex-shrink: 0; }
    .parties { margin: 24px 0 8px 0; }
    .bill-to { font-weight: 600; margin-bottom: 4px; }
    table { width: 100%; border-collapse: collapse; margin-top: 16px; }
    th, td { text-align: left; padding: 8px 0; border-bottom: 1px solid #f3f4f6; }
    th { font-size: 11px; letter-spacing: 0.06em; text-transform: uppercase; color: #6b7280; }
    td.num, th.num { text-align: right; }
    td.label { color: #6b7280; }
    tfoot td { border-bottom: none; padding-top: 10px; }
    tfoot tr.total td { font-size: 16px; font-weight: 700; border-top: 2px solid #111827; }
    .notes { margin-top: 20px; font-size: 12px; }
    .status { font-size: 12px; color: #6b7280; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="top">
      $letterhead
      <div class="meta">
        <h1>Invoice</h1>
        <div>${escapeHtml(invoiceNumber)}</div>
        <div><span class="muted">Issued</span> ${escapeHtml(issueDateFormatted)}</div>
        <div><span class="muted">Due</span> ${escapeHtml(dueDateFormatted)}</div>
        ${statusLabel == null || statusLabel.isEmpty ? '' : '<div class="status">${escapeHtml(statusLabel)}</div>'}
      </div>
    </div>

    <div class="parties">
      <div class="bill-to">Bill to</div>
      ${line(null, tenantName)}
      ${line('Unit', unitNumber)}
      ${line(null, tenantAddress)}
      ${line(null, tenantPhone)}
      ${line(null, tenantEmail)}
    </div>

    <table>
      <thead>
        <tr><th>Description</th><th class="num">Amount</th></tr>
      </thead>
      <tbody>
        $rows
      </tbody>
      <tfoot>
        <tr><td class="label">Subtotal</td><td class="num">${escapeHtml(subtotalFormatted)}</td></tr>
        $taxRow
        <tr class="total"><td>Total</td><td class="num">${escapeHtml(totalFormatted)}</td></tr>
        <tr><td class="label">Balance due</td><td class="num">${escapeHtml(balanceFormatted)}</td></tr>
      </tfoot>
    </table>

    $notesBlock
  </div>
</body>
</html>
''';
}
