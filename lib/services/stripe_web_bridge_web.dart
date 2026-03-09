// Stripe Payment Element bridge - web implementation (dart:js_interop)

import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:flutter/foundation.dart';

class StripeConfirmResult {
  final bool succeeded;
  final String? error;

  const StripeConfirmResult({required this.succeeded, this.error});
}

class StripeWebBridge {
  static JSObject? _stripe;
  static JSObject? _elements;
  static JSObject? _paymentElement;
  static String _currentMode = '';

  static void initialize(String publishableKey) {
    try {
      final win = html.window as JSObject;
      final stripeCtor = win['Stripe'];
      if (stripeCtor == null || stripeCtor.isUndefinedOrNull) {
        throw Exception('Stripe not loaded. Add <script src="https://js.stripe.com/v3/"></script> to index.html');
      }
      _stripe = (stripeCtor as JSFunction).callAsConstructor<JSObject>(publishableKey.toJS);
    } catch (e) {
      debugPrint('StripeWebBridge init error: $e');
    }
  }

  static Future<void> mountSetupElement(String containerId, String clientSecret) async {
    if (_stripe == null) throw Exception('Stripe not initialized');
    await _unmount();
    _currentMode = 'setup';
    final opts = {'clientSecret': clientSecret}.jsify();
    _elements = _stripe!.callMethod<JSObject>('elements'.toJS, opts);
    _paymentElement = _elements!.callMethod<JSObject>('create'.toJS, 'payment'.toJS, {}.jsify());
    final container = html.document.getElementById(containerId);
    if (container == null) throw Exception('Container $containerId not found');
    _paymentElement!.callMethod('mount'.toJS, container as JSAny);
  }

  static Future<void> mountPaymentElement(String containerId, String clientSecret) async {
    if (_stripe == null) throw Exception('Stripe not initialized');
    await _unmount();
    _currentMode = 'payment';
    final opts = {'clientSecret': clientSecret}.jsify();
    _elements = _stripe!.callMethod<JSObject>('elements'.toJS, opts);
    _paymentElement = _elements!.callMethod<JSObject>('create'.toJS, 'payment'.toJS, {}.jsify());
    final container = html.document.getElementById(containerId);
    if (container == null) throw Exception('Container $containerId not found');
    _paymentElement!.callMethod('mount'.toJS, container as JSAny);
  }

  static Future<void> _unmount() async {
    if (_paymentElement != null) {
      try {
        _paymentElement!.callMethod('unmount'.toJS);
      } catch (_) {}
      _paymentElement = null;
    }
    _elements = null;
    _currentMode = '';
  }

  static Future<void> unmount() => _unmount();

  static Future<StripeConfirmResult> confirmSetup(String returnUrl) async {
    if (_stripe == null || _elements == null || _currentMode != 'setup') {
      return const StripeConfirmResult(succeeded: false, error: 'Not ready');
    }
    return _confirm(returnUrl, 'confirmSetup');
  }

  static Future<StripeConfirmResult> confirmPayment(String returnUrl) async {
    if (_stripe == null || _elements == null || _currentMode != 'payment') {
      return const StripeConfirmResult(succeeded: false, error: 'Not ready');
    }
    return _confirm(returnUrl, 'confirmPayment');
  }

  static Future<StripeConfirmResult> _confirm(String returnUrl, String method) async {
    try {
      final confirmParams = {'return_url': returnUrl}.jsify();
      final options = {'elements': _elements!, 'confirmParams': confirmParams}.jsify();
      final promise = _stripe!.callMethod<JSPromise>(method.toJS, options);
      final value = await promise.toDart;
      if (value == null || value.isUndefinedOrNull) {
        return const StripeConfirmResult(succeeded: true);
      }
      final resultObj = value as JSObject;
      final err = resultObj['error'];
      if (err != null && !err.isUndefinedOrNull) {
        final errObj = err as JSObject;
        final msg = errObj['message'];
        return StripeConfirmResult(succeeded: false, error: msg?.dartify().toString() ?? 'Unknown error');
      }
      return const StripeConfirmResult(succeeded: true);
    } catch (e) {
      return StripeConfirmResult(succeeded: false, error: e.toString());
    }
  }

  static bool get isInitialized => _stripe != null;
}
