// Stripe Payment Element bridge - conditional export for web / stub for other platforms

export 'stripe_web_bridge_stub.dart'
    if (dart.library.html) 'stripe_web_bridge_web.dart';
