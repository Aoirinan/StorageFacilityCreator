// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
// The analyzer resolves lib/ against the Flutter (non-web) platform, so it
// does not see dart:js_util even though this file is only ever compiled for
// web through the conditional export in print_util.dart. The web build
// compiles it fine.
// ignore: uri_does_not_exist, avoid_web_libraries_in_flutter
import 'dart:js_util' as js_util;

import 'package:sfcapp/utils/print_documents.dart';

/// Triggers the browser print dialog (web only).
void printWindow() {
  html.window.print();
}

/// Opens a print-friendly HTML document so the receipt fills the page instead
/// of the full Flutter UI (sidebar, modal chrome, etc.). The facility's
/// letterhead (logo, name, addresses) heads it when it is passed in.
void printPaymentReceipt({
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
  _printDocument(buildPaymentReceiptHtml(
    tenantName: tenantName,
    amountFormatted: amountFormatted,
    dateFormatted: dateFormatted,
    transactionId: transactionId,
    businessName: businessName,
    businessAddress: businessAddress,
    businessMailingAddress: businessMailingAddress,
    businessPhone: businessPhone,
    businessEmail: businessEmail,
    logoUrl: logoUrl,
  ));
}

/// Opens a print-friendly invoice so it can be printed or saved as a PDF.
///
/// The facility's letterhead (logo, details, and the mailing address payments
/// go to) sits at the top and the tenant's details underneath, which is what
/// makes it a document you can hand or post to a customer. The browser's own
/// print dialog offers "Save as PDF", so this covers printing and emailing
/// without waiting on a generated file. See print_documents.dart for the HTML.
void printInvoice({
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
  _printDocument(buildInvoiceHtml(
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
    invoiceNumber: invoiceNumber,
    issueDateFormatted: issueDateFormatted,
    dueDateFormatted: dueDateFormatted,
    lineItems: lineItems,
    subtotalFormatted: subtotalFormatted,
    taxFormatted: taxFormatted,
    totalFormatted: totalFormatted,
    balanceFormatted: balanceFormatted,
    notes: notes,
    statusLabel: statusLabel,
  ));
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

  // A previous print's frame, if the operator printed twice in a row.
  for (final stale in html.document.querySelectorAll('iframe[data-sfc-print]')) {
    stale.remove();
  }
  iframe.setAttribute('data-sfc-print', '1');
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

  iframe.onLoad.listen((_) async {
    // The frame's load event already waits for the images in a srcdoc
    // document (the facility logo), loaded or failed. This is the belt to that
    // braces: a logo still decoding gets a few seconds, and a slow or broken
    // one never holds the print back beyond that.
    await _waitForImages(iframe);
    final cw = iframe.contentWindow;
    if (cw == null) {
      html.window.console.error('Print failed: the frame has no window');
      cleanup();
      return;
    }
    try {
      // The window is fetched off the element with js_util rather than used
      // as `cw.print()`, and the reason is worth keeping. `iframe.contentWindow`
      // hands back a dart:html WindowBase wrapper: the old
      // `if (cw is! html.Window) return;` guard was therefore always true and
      // returned before printing, and calling js_util on the wrapper fails the
      // same way — "method not found: 'focus' (n.focus is not a function)".
      // Reading contentWindow off the element gives the real JS window, which
      // does have print. Measured in the browser both ways.
      final jsWindow = js_util.getProperty<Object?>(iframe, 'contentWindow');
      if (jsWindow == null) {
        html.window.console.error('Print failed: no window on the frame');
        cleanup();
        return;
      }
      js_util.callMethod<void>(jsWindow, 'print', const []);
    } catch (e) {
      // Leave a trace rather than failing mutely.
      html.window.console.error('Print failed: $e');
      cleanup();
      return;
    }
    // Deliberately no short timer here. Removing the frame while Chrome is
    // still opening its preview cancels the preview, which looks exactly like
    // a button that does nothing. The frame is invisible and weighs a few KB,
    // so it can wait for the dialog to be done with it.
    Future<void>.delayed(const Duration(minutes: 5), cleanup);
  });
}

/// Resolves once every <img> in [iframe]'s document is complete (or failed),
/// or after [timeout], whichever comes first. Never throws.
Future<void> _waitForImages(
  html.IFrameElement iframe, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  try {
    final doc = js_util.getProperty<Object?>(iframe, 'contentDocument');
    if (doc == null) return;
    final images =
        js_util.callMethod<Object>(doc, 'querySelectorAll', const ['img']);
    final count = js_util.getProperty<int>(images, 'length');
    final pending = <Future<void>>[];
    for (var i = 0; i < count; i++) {
      final img = js_util.callMethod<Object>(images, 'item', [i]);
      if (js_util.getProperty<bool>(img, 'complete') == true) continue;
      pending.add(
        js_util
            .promiseToFuture<void>(js_util.callMethod<Object>(img, 'decode', const []))
            .catchError((Object _) {}),
      );
    }
    if (pending.isEmpty) return;
    await Future.wait(pending).timeout(timeout, onTimeout: () => const []);
  } catch (_) {
    // Print without the logo rather than not at all.
  }
}
