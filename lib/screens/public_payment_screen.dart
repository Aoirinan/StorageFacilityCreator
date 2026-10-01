import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/services/public_payment_link_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/widgets/keyboard_scrollable.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// The server calls the payment page makes. Tests pass their own.
class PublicPaymentApi {
  const PublicPaymentApi();

  Future<PublicPaymentLink?> getLink(String token) =>
      PublicPaymentLinkService.getPaymentLink(token);

  Future<PublicCheckoutStart> startCheckout(String token) =>
      PublicPaymentLinkService.startCheckout(token);

  Future<String> confirmCheckout(String token, String sessionId) =>
      PublicPaymentLinkService.confirmCheckout(token: token, sessionId: sessionId);
}

/// Public payment screen - accessible via /pay?token=...
/// No authentication required
class PublicPaymentScreen extends StatefulWidget {
  final String? token;

  /// Where Stripe sent the tenant back from. Read from the address bar on web
  /// when not given.
  final PublicCheckoutReturn? checkoutReturn;
  final PublicPaymentApi api;

  /// How often, and how many times, to re-check a payment that is confirming.
  final Duration pollInterval;
  final int maxPolls;

  const PublicPaymentScreen({
    super.key,
    this.token,
    this.checkoutReturn,
    this.api = const PublicPaymentApi(),
    this.pollInterval = const Duration(seconds: 3),
    this.maxPolls = 10,
  });

  @override
  State<PublicPaymentScreen> createState() => _PublicPaymentScreenState();
}

/// Paid states never show Pay Now: a tenant back from Stripe who sees the
/// button again pays again.
enum _Phase { loading, error, pay, confirming, stillConfirming, paid, received }

class _PublicPaymentScreenState extends State<PublicPaymentScreen> {
  PublicPaymentLink? _paymentLink;
  _Phase _phase = _Phase.loading;
  String? _error;
  bool _isProcessing = false;
  String? _token;
  String? _returnSessionId;
  Timer? _pollTimer;
  int _polls = 0;

  /// Bumped whenever polling restarts ("Check again"), so an answer from an
  /// earlier round cannot schedule more polls or overwrite the page.
  int _pollGeneration = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _set(VoidCallback update) {
    if (mounted) setState(update);
  }

  Future<void> _start() async {
    final token = widget.token ?? _getTokenFromUrl();
    if (token == null || token.isEmpty) {
      _set(() {
        _error = 'Payment link token is missing';
        _phase = _Phase.error;
      });
      return;
    }
    _token = token;
    final checkoutReturn = widget.checkoutReturn ??
        (kIsWeb ? PublicCheckoutReturn.fromUri(Uri.base) : null);
    if (checkoutReturn != null && checkoutReturn.isSuccess) {
      await _confirm(checkoutReturn.sessionId!);
    } else {
      await _loadPaymentLink();
    }
  }

  Future<void> _loadPaymentLink() async {
    final token = _token;
    if (token == null) return;
    try {
      final link = await widget.api.getLink(token);
      if (link == null) {
        _set(() {
          _error = 'Payment link not found or has expired';
          _phase = _Phase.error;
        });
        return;
      }
      // Paid first: a paid link is not "active", and used to be reported as
      // "no longer active" to the tenant who had just paid it.
      if (link.status == 'paid') {
        _set(() {
          _paymentLink = link;
          _phase = _Phase.paid;
        });
        return;
      }
      if (!link.isActive) {
        _set(() {
          _error = link.isExpired
              ? 'This payment link has expired'
              : 'This payment link is no longer active';
          _phase = _Phase.error;
        });
        return;
      }
      _set(() {
        _paymentLink = link;
        _phase = _Phase.pay;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error loading payment link: $e');
      }
      _set(() {
        _error = 'Error loading payment link: $e';
        _phase = _Phase.error;
      });
    }
  }

  /// Stripe sent the tenant back after paying: record it now.
  Future<void> _confirm(String sessionId) async {
    final token = _token;
    if (token == null) return;
    _pollTimer?.cancel();
    _pollGeneration++;
    _returnSessionId = sessionId;
    _set(() => _phase = _Phase.confirming);
    String status;
    try {
      status = await widget.api.confirmCheckout(token, sessionId);
    } on FirebaseFunctionsException catch (e) {
      // Not this link's session (an old bookmark, a stale tab): the link's own
      // status decides what to show.
      if (const {'not-found', 'permission-denied', 'invalid-argument'}.contains(e.code)) {
        await _loadPaymentLink();
        return;
      }
      status = 'processing';
    } catch (_) {
      // Stripe only returns here after taking the payment, so never offer
      // Pay Now on a failed check; keep looking instead.
      status = 'processing';
    }
    switch (status) {
      case 'paid':
        await _showPaid();
        break;
      case 'received':
        _set(() => _phase = _Phase.received);
        break;
      case 'unpaid':
        await _loadPaymentLink();
        break;
      default:
        _startPolling();
    }
  }

  Future<void> _showPaid() async {
    final token = _token;
    PublicPaymentLink? link;
    try {
      link = token == null ? null : await widget.api.getLink(token);
    } catch (_) {
      link = null;
    }
    _set(() {
      _paymentLink = link ?? _paymentLink;
      _phase = _Phase.paid;
    });
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _polls = 0;
    final generation = ++_pollGeneration;
    _set(() => _phase = _Phase.confirming);
    _schedulePoll(generation);
  }

  /// One check at a time: the next is scheduled only after this one answers,
  /// so a slow answer cannot land after a later one has settled the page.
  void _schedulePoll(int generation) {
    _pollTimer = Timer(widget.pollInterval, () async {
      _polls++;
      final settled = await _pollOnce();
      if (!mounted || generation != _pollGeneration || settled) return;
      if (_polls >= widget.maxPolls) {
        _set(() => _phase = _Phase.stillConfirming);
      } else {
        _schedulePoll(generation);
      }
    });
  }

  /// Re-asks the server to confirm the session Stripe returned with (the
  /// confirm is idempotent), so the page reaches paid even when the webhook
  /// never marks the link. Falls back to the link's own status. True once the
  /// page has moved to a final state.
  Future<bool> _pollOnce() async {
    final token = _token;
    if (token == null) return false;
    final sessionId = _returnSessionId;
    if (sessionId != null) {
      try {
        final status = await widget.api.confirmCheckout(token, sessionId);
        if (!mounted) return true;
        if (status == 'paid') {
          await _showPaid();
          return true;
        }
        if (status == 'received') {
          _set(() => _phase = _Phase.received);
          return true;
        }
      } catch (_) {
        // Still settling or unreachable: never re-offer Pay Now from a poll.
      }
    }
    PublicPaymentLink? link;
    try {
      link = await widget.api.getLink(token);
    } catch (_) {
      link = null;
    }
    if (!mounted) return true;
    if (link != null && link.status == 'paid') {
      _set(() {
        _paymentLink = link;
        _phase = _Phase.paid;
      });
      return true;
    }
    return false;
  }

  String? _getTokenFromUrl() {
    // The token rides on the hash route (#/pay?token=…); older links put it
    // before the hash. Accept both.
    final uri = Uri.base;
    final fromQuery = uri.queryParameters['token'];
    if (fromQuery != null && fromQuery.isNotEmpty) return fromQuery;
    final fragment = uri.fragment;
    final q = fragment.indexOf('?');
    if (q < 0) return null;
    return Uri.splitQueryString(fragment.substring(q + 1))['token'];
  }

  Future<void> _proceedToPayment() async {
    // A second tap in the same frame, before the rebuild disables the
    // button, would open a second checkout.
    if (_paymentLink == null || _isProcessing) return;

    setState(() {
      _isProcessing = true;
    });

    try {
      // The server hands back the link's open session, or reports it paid.
      final start = await widget.api.startCheckout(_paymentLink!.token);
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
      });
      if (start.alreadyPaid) {
        await _showPaid();
        return;
      }
      _openCheckout(start.checkoutUrl!);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating checkout: $e');
      }
      final alreadyProcessing = e is FirebaseFunctionsException && e.code == 'failed-precondition';
      _set(() {
        _error = alreadyProcessing
            ? (e.message ?? 'This payment link can no longer be paid.')
            : 'Error creating payment session. Please try again or contact support.';
        _phase = _Phase.error;
        _isProcessing = false;
      });
    }
  }

  void _openCheckout(String url) {
    if (kIsWeb) {
      // On web, open in new tab
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication).then((_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Opening payment checkout...'),
              backgroundColor: AppTheme.success,
            ),
          );
        }
      }).catchError((e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error opening checkout: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      });
    } else {
      // On mobile, show in WebView dialog
      _showCheckoutWebView(url);
    }
  }

  void _showCheckoutWebView(String url) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: SizedBox(
          width: double.infinity,
          height: double.infinity,
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.primaryBlue,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.payment, color: AppTheme.textOnDark),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Complete Payment',
                        style: TextStyle(
                          color: AppTheme.textOnDark,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: AppTheme.textOnDark),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              // WebView
              Expanded(
                child: WebViewWidget(
                  controller: WebViewController()
                    ..setJavaScriptMode(JavaScriptMode.unrestricted)
                    ..setNavigationDelegate(
                      NavigationDelegate(
                        onPageFinished: (url) {
                          final checkoutReturn = PublicCheckoutReturn.fromUri(Uri.parse(url));
                          if (checkoutReturn?.status == 'success') {
                            // Payment succeeded
                            Navigator.of(context).pop();
                            _handlePaymentSuccess(checkoutReturn!.sessionId);
                          } else if (checkoutReturn?.status == 'cancel') {
                            // Payment cancelled
                            Navigator.of(context).pop();
                          }
                        },
                      ),
                    )
                    ..loadRequest(Uri.parse(url)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _handlePaymentSuccess(String? sessionId) {
    if (sessionId != null) {
      unawaited(_confirm(sessionId));
    } else {
      _startPolling();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Public page - no ModernPageWrapper (no sidebar)
    return Scaffold(
      body: KeyboardScrollable(
        child: switch (_phase) {
          _Phase.loading => const Center(child: CircularProgressIndicator()),
          _Phase.error => _buildErrorView(),
          _Phase.pay => _paymentLink == null ? _buildErrorView() : _buildPaymentView(),
          _Phase.confirming => _buildConfirmingView(stillWaiting: false),
          _Phase.stillConfirming => _buildConfirmingView(stillWaiting: true),
          _Phase.paid => _buildSuccessView(),
          _Phase.received => _buildReceivedView(),
        },
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: AppTheme.error),
            const SizedBox(height: 16),
            const Text(
              'Payment Link Error',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? 'An unknown error occurred',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => context.go('/'),
              child: const Text('Go to Home'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfirmingView({required bool stillWaiting}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (stillWaiting)
              const Icon(Icons.hourglass_top, size: 64, color: AppTheme.primaryBlue)
            else
              const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              stillWaiting ? 'Payment Processing' : 'Confirming your payment…',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              "You don't need to pay again.",
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary),
            ),
            if (stillWaiting) ...[
              const SizedBox(height: 8),
              const Text(
                'Your payment is still being confirmed. Check again in a few minutes.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  final sessionId = _returnSessionId;
                  if (sessionId != null) {
                    unawaited(_confirm(sessionId));
                  } else {
                    _startPolling();
                  }
                },
                child: const Text('Check again'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSuccessView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle, size: 64, color: AppTheme.success),
            const SizedBox(height: 16),
            const Text(
              'Payment Successful!',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            if (_paymentLink != null)
              Text(
                'Amount: \$${_paymentLink!.amount.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 18,
                  color: AppTheme.textSecondary,
                ),
              ),
            const SizedBox(height: 24),
            // No receipt claim: whether Stripe emails one depends on the
            // facility's own Stripe settings, which this page cannot see.
            const Text(
              'Thank you. Your payment has been received.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReceivedView() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_outline, size: 64, color: AppTheme.success),
            SizedBox(height: 16),
            Text(
              'Payment Received',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: AppTheme.textPrimary,
              ),
            ),
            SizedBox(height: 8),
            Text(
              "Your payment was received, and the facility has been notified. You don't need to pay again.",
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPaymentView() {
    final link = _paymentLink!;

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 40),
                // Logo/Header
                const Icon(Icons.payment, size: 64, color: AppTheme.primaryBlue),
                const SizedBox(height: 16),
                const Text(
                  'Payment Request',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 32),
                // Payment Details Card
                Card(
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Payment Details',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 16),
                        _buildDetailRow('Description', link.description),
                        const Divider(),
                        _buildDetailRow(
                          'Amount',
                          '\$${link.amount.toStringAsFixed(2)}',
                          isAmount: true,
                        ),
                        const Divider(),
                        _buildDetailRow(
                          'Expires',
                          _formatDate(link.expiresAt),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // Pay Button
                ElevatedButton(
                  onPressed: _isProcessing ? null : _proceedToPayment,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryBlue,
                    foregroundColor: AppTheme.textOnDark,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: _isProcessing
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(AppTheme.textOnDark),
                          ),
                        )
                      : const Text(
                          'Pay Now',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
                const SizedBox(height: 16),
                // Security Notice
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.lock, size: 16, color: AppTheme.textTertiary),
                    SizedBox(width: 8),
                    Text(
                      'Secure payment powered by Stripe',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.textTertiary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, {bool isAmount = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 14,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: isAmount ? AppTheme.primaryBlue : AppTheme.textPrimary,
              fontSize: isAmount ? 20 : 14,
              fontWeight: isAmount ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }
}
