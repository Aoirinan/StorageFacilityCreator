import 'dart:async';
import 'dart:html' as html;
import 'dart:ui_web' as ui;
import 'package:flutter/material.dart';

int _viewIdCounter = 0;
final Map<int, _StripeEmbedState> _stateByViewId = {};

void _registerFactory() {
  try {
    // ignore: undefined_prefixed_name
    ui.platformViewRegistry.registerViewFactory(
      'stripe-embed-iframe',
      (int viewId) {
        final iframe = html.IFrameElement()
          ..src = '${html.window.location.origin}/stripe_embedded.html'
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.border = 'none';
        _stateByViewId[viewId] = _StripeEmbedState(iframe, viewId);
        return iframe;
      },
    );
  } catch (_) {}
}

bool _registered = false;

Widget buildPaymentElementHost({
  required String containerId,
  required double height,
}) {
  if (!_registered) {
    _registered = true;
    _registerFactory();
  }
  return _StripePaymentElementHost(height: height, containerId: containerId);
}

class _StripePaymentElementHost extends StatefulWidget {
  final double height;
  final String containerId;

  const _StripePaymentElementHost({required this.height, required this.containerId});

  @override
  State<_StripePaymentElementHost> createState() => _StripePaymentElementHostState();
}

class _StripePaymentElementHostState extends State<_StripePaymentElementHost> {
  StreamSubscription<html.MessageEvent>? _sub;
  int? _viewId;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: HtmlElementView(
        viewType: 'stripe-embed-iframe',
      ),
    );
  }
}

class _StripeEmbedState {
  final html.IFrameElement iframe;
  final int viewId;

  _StripeEmbedState(this.iframe, this.viewId);
}

void sendStripeEmbedConfig({
  required String publishableKey,
  required String clientSecret,
  required String mode,
  required String returnUrl,
}) {
  for (final s in _stateByViewId.values) {
    s.iframe.contentWindow?.postMessage({
      'type': 'STRIPE_EMBED_INIT',
      'publishableKey': publishableKey,
      'clientSecret': clientSecret,
      'mode': mode,
      'returnUrl': returnUrl,
    }, '*');
    break;
  }
}
