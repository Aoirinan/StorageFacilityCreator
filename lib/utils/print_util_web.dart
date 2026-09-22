// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

/// Triggers the browser print dialog (web only).
void printWindow() {
  html.window.print();
}

String _escapeHtml(String s) {
  return s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
}

/// Opens a print-friendly HTML document so the receipt fills the page instead
/// of the full Flutter UI (sidebar, modal chrome, etc.).
void printPaymentReceipt({
  required String tenantName,
  required String amountFormatted,
  required String dateFormatted,
  String? transactionId,
  String? businessName,
}) {
  final org = businessName != null && businessName.isNotEmpty
      ? _escapeHtml(businessName)
      : 'Storage Facility Creator';
  final tenant = _escapeHtml(tenantName);
  final amount = _escapeHtml(amountFormatted);
  final when = _escapeHtml(dateFormatted);
  final txn = transactionId != null && transactionId.isNotEmpty
      ? _escapeHtml(transactionId)
      : null;

  final txnBlock = txn == null
      ? ''
      : '''
      <div class="row">
        <span class="label">Transaction ID</span>
        <span class="value mono">$txn</span>
      </div>''';

  final doc = '''
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
    .brand {
      font-size: 11px;
      letter-spacing: 0.06em;
      text-transform: uppercase;
      color: #6b7280;
      margin-bottom: 6px;
    }
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
    <div class="brand">$org</div>
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

  _printDocument(doc);
}

/// Opens a print-friendly invoice so it can be printed or saved as a PDF.
///
/// The facility's details sit at the top and the tenant's underneath, which is
/// what makes it a document you can hand or post to a customer. The browser's
/// own print dialog offers "Save as PDF", so this covers printing and emailing
/// without waiting on a generated file.
void printInvoice({
  required String facilityName,
  String? facilityAddress,
  String? facilityPhone,
  String? facilityEmail,
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
    if (value == null || value.trim().isEmpty) return '';
    final text = _escapeHtml(value.trim());
    return label == null
        ? '<div>$text</div>'
        : '<div><span class="muted">${_escapeHtml(label)}</span> $text</div>';
  }

  final rows = lineItems
      .map((item) => '''
      <tr>
        <td>${_escapeHtml(item.description)}</td>
        <td class="num">${_escapeHtml(item.amount)}</td>
      </tr>''')
      .join();

  final taxRow = (taxFormatted == null || taxFormatted.isEmpty)
      ? ''
      : '''
      <tr>
        <td class="label">Tax</td>
        <td class="num">${_escapeHtml(taxFormatted)}</td>
      </tr>''';

  final notesBlock = (notes == null || notes.trim().isEmpty)
      ? ''
      : '<div class="notes"><span class="muted">Notes</span><br>${_escapeHtml(notes.trim())}</div>';

  final doc = '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Invoice ${_escapeHtml(invoiceNumber)}</title>
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
    .facility-name { font-size: 20px; font-weight: 700; margin-bottom: 2px; }
    h1 { font-size: 20px; font-weight: 700; margin: 0 0 4px 0; text-align: right; }
    .meta { text-align: right; }
    .muted { color: #6b7280; }
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
      <div>
        <div class="facility-name">${_escapeHtml(facilityName)}</div>
        ${line(null, facilityAddress)}
        ${line(null, facilityPhone)}
        ${line(null, facilityEmail)}
      </div>
      <div class="meta">
        <h1>Invoice</h1>
        <div>${_escapeHtml(invoiceNumber)}</div>
        <div><span class="muted">Issued</span> ${_escapeHtml(issueDateFormatted)}</div>
        <div><span class="muted">Due</span> ${_escapeHtml(dueDateFormatted)}</div>
        ${statusLabel == null || statusLabel.isEmpty ? '' : '<div class="status">${_escapeHtml(statusLabel)}</div>'}
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
        <tr><td class="label">Subtotal</td><td class="num">${_escapeHtml(subtotalFormatted)}</td></tr>
        $taxRow
        <tr class="total"><td>Total</td><td class="num">${_escapeHtml(totalFormatted)}</td></tr>
        <tr><td class="label">Balance due</td><td class="num">${_escapeHtml(balanceFormatted)}</td></tr>
      </tfoot>
    </table>

    $notesBlock
  </div>
</body>
</html>
''';

  _printDocument(doc);
}

/// Renders [doc] in a hidden frame and opens the print dialog on it, so the
/// page being printed is the document rather than the whole app.
void _printDocument(String doc) {
  final iframe = html.IFrameElement()
    ..setAttribute('aria-hidden', 'true')
    ..style.border = '0'
    ..style.width = '0'
    ..style.height = '0'
    ..style.position = 'fixed'
    ..style.right = '0'
    ..style.bottom = '0';

  html.document.body!.append(iframe);

  // srcdoc, not a blob URL. A blob: document is a different origin from this
  // page, so reaching into it for contentWindow.print() throws
  // "Blocked a frame with origin ... from accessing a cross-origin frame" and
  // the print dialog never opens — silently, because the throw happens inside
  // the load listener. A srcdoc document inherits this page's origin, so
  // print() is reachable. Verified in the browser before changing it.
  iframe.srcdoc = doc;

  var cleaned = false;
  void cleanup() {
    if (cleaned) return;
    cleaned = true;
    iframe.remove();
  }

  iframe.onLoad.listen((_) {
    final cw = iframe.contentWindow;
    if (cw is! html.Window) {
      cleanup();
      return;
    }
    try {
      cw.print();
    } catch (e) {
      // Leave a trace rather than failing mutely, which is exactly how the
      // blob version hid this for as long as it did.
      html.window.console.error('Print failed: $e');
      cleanup();
      return;
    }
    // dart:html does not expose onAfterPrint on Window; clean up shortly after the dialog closes.
    Future<void>.delayed(const Duration(seconds: 1), cleanup);
    Future<void>.delayed(const Duration(seconds: 60), cleanup);
  });
}
