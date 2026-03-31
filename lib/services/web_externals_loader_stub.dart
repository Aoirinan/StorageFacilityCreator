/// No-op on non-web platforms (pdfx / Stripe bridge use native paths).
Future<void> ensureStripeJsForWeb() async {}

Future<void> ensurePdfJsForWeb() async {}
