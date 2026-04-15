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

  final iframe = html.IFrameElement()
    ..setAttribute('aria-hidden', 'true')
    ..style.border = '0'
    ..style.width = '0'
    ..style.height = '0'
    ..style.position = 'fixed'
    ..style.right = '0'
    ..style.bottom = '0';

  html.document.body!.append(iframe);

  final blob = html.Blob([doc], 'text/html');
  final url = html.Url.createObjectUrlFromBlob(blob);
  iframe.src = url;

  var cleaned = false;
  void cleanup() {
    if (cleaned) return;
    cleaned = true;
    html.Url.revokeObjectUrl(url);
    iframe.remove();
  }

  iframe.onLoad.listen((_) {
    final cw = iframe.contentWindow;
    if (cw == null) {
      cleanup();
      return;
    }
    cw.onAfterPrint.listen((_) => cleanup());
    cw.print();
    // Some browsers omit afterPrint; avoid leaking the iframe if it never fires.
    Future<void>.delayed(const Duration(seconds: 60), cleanup);
  });
}
