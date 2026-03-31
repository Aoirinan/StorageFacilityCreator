import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Loads Stripe.js once via [window.sfcLoadStripeJs] from `web/index.html`.
Future<void> ensureStripeJsForWeb() async {
  final win = html.window as JSObject;
  final stripeCtor = win['Stripe'];
  if (stripeCtor != null && !stripeCtor.isUndefinedOrNull) return;

  final loader = win['sfcLoadStripeJs'];
  if (loader == null || loader.isUndefinedOrNull) {
    throw StateError(
      'sfcLoadStripeJs is not defined. Ensure web/index.html includes the SFC external script loaders.',
    );
  }
  final promise =
      (loader as JSObject).callMethod<JSPromise>('call'.toJS, win);
  await promise.toDart;
}

/// Loads PDF.js once for [pdfx] on web via [window.sfcLoadPdfJs] from `web/index.html`.
Future<void> ensurePdfJsForWeb() async {
  final win = html.window as JSObject;
  final pdfjs = win['pdfjsLib'];
  if (pdfjs != null && !pdfjs.isUndefinedOrNull) return;

  final loader = win['sfcLoadPdfJs'];
  if (loader == null || loader.isUndefinedOrNull) {
    throw StateError(
      'sfcLoadPdfJs is not defined. Ensure web/index.html includes the SFC external script loaders.',
    );
  }
  final promise =
      (loader as JSObject).callMethod<JSPromise>('call'.toJS, win);
  await promise.toDart;
}
