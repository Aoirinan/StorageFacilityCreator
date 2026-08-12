import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import '../services/public_payment_link_service.dart';
import '../services/stripe_service.dart';
import '../services/tenant_service.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../widgets/keyboard_scrollable.dart';

/// Public payment screen - accessible via /pay?token=...
/// No authentication required
class PublicPaymentScreen extends StatefulWidget {
  final String? token;

  const PublicPaymentScreen({
    super.key,
    this.token,
  });

  @override
  State<PublicPaymentScreen> createState() => _PublicPaymentScreenState();
}

class _PublicPaymentScreenState extends State<PublicPaymentScreen> {
  PublicPaymentLink? _paymentLink;
  bool _isLoading = true;
  String? _error;
  bool _isProcessing = false;
  String? _checkoutUrl;

  @override
  void initState() {
    super.initState();
    _loadPaymentLink();
  }

  Future<void> _loadPaymentLink() async {
    final token = widget.token ?? _getTokenFromUrl();
    if (token == null || token.isEmpty) {
      setState(() {
        _error = 'Payment link token is missing';
        _isLoading = false;
      });
      return;
    }

    try {
      final link = await PublicPaymentLinkService.getPaymentLink(token);
      if (link == null) {
        setState(() {
          _error = 'Payment link not found or has expired';
          _isLoading = false;
        });
        return;
      }

      if (!link.isActive) {
        setState(() {
          _error = link.isExpired
              ? 'This payment link has expired'
              : 'This payment link is no longer active';
          _isLoading = false;
        });
        return;
      }

      setState(() {
        _paymentLink = link;
        _isLoading = false;
      });

      // Load tenant info
      _loadTenantInfo();
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error loading payment link: $e');
      }
      setState(() {
        _error = 'Error loading payment link: $e';
        _isLoading = false;
      });
    }
  }

  String? _getTokenFromUrl() {
    // Try to get token from query parameters
    final uri = Uri.base;
    return uri.queryParameters['token'];
  }

  Future<void> _loadTenantInfo() async {
    if (_paymentLink == null) return;

    try {
      // Optional: Load tenant info for display
      // final tenant = await TenantService.getTenant(
      //   facilityId: _paymentLink!.facilityId,
      //   tenantId: _paymentLink!.tenantId,
      // );
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Could not load tenant info: $e');
      }
    }
  }

  Future<void> _proceedToPayment() async {
    if (_paymentLink == null) return;

    setState(() {
      _isProcessing = true;
    });

    try {
      // Create Stripe checkout session using public payment link token
      final checkoutUrl = await StripeService.createPublicPaymentCheckout(
        token: _paymentLink!.token,
      );

      setState(() {
        _checkoutUrl = checkoutUrl;
        _isProcessing = false;
      });

      // Open checkout
      _openCheckout(checkoutUrl);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating checkout: $e');
      }
      setState(() {
        _error = 'Error creating payment session. Please try again or contact support.';
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
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: Container(
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
                      color: Colors.black.withOpacity(0.1),
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
                          if (url.contains('status=success') || url.contains('payment/success')) {
                            // Payment succeeded
                            Navigator.of(context).pop();
                            _handlePaymentSuccess();
                          } else if (url.contains('status=cancel') || url.contains('payment/cancel')) {
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

  void _handlePaymentSuccess() {
    // Reload to show success state
    setState(() {
      _isLoading = true;
    });
    Future.delayed(const Duration(seconds: 2), () {
      _loadPaymentLink();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Public page - no ModernPageWrapper (no sidebar)
    return Scaffold(
      body: KeyboardScrollable(
        child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildErrorView()
              : _paymentLink == null
                  ? _buildErrorView()
                  : _paymentLink!.status == 'paid'
                      ? _buildSuccessView()
                      : _buildPaymentView(),
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
            Icon(Icons.error_outline, size: 64, color: AppTheme.error),
            const SizedBox(height: 16),
            Text(
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
              style: TextStyle(color: AppTheme.textSecondary),
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

  Widget _buildSuccessView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle, size: 64, color: AppTheme.success),
            const SizedBox(height: 16),
            Text(
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
                style: TextStyle(
                  fontSize: 18,
                  color: AppTheme.textSecondary,
                ),
              ),
            const SizedBox(height: 24),
            Text(
              'Thank you for your payment. A receipt has been sent to your email.',
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
                Icon(Icons.payment, size: 64, color: AppTheme.primaryBlue),
                const SizedBox(height: 16),
                Text(
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
                        Text(
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.lock, size: 16, color: AppTheme.textTertiary),
                    const SizedBox(width: 8),
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
            style: TextStyle(
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

