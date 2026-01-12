import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/stripe_service.dart';
import '../models/facility_model.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';
import '../widgets/keyboard_scrollable.dart';
import '../utils/error_message_helper.dart';

/// Screen for facility owners to connect their Stripe account
/// This enables them to receive tenant rent payments directly
class StripeConnectOnboardingScreen extends StatefulWidget {
  final FacilityModel facility;

  const StripeConnectOnboardingScreen({
    super.key,
    required this.facility,
  });

  @override
  State<StripeConnectOnboardingScreen> createState() => _StripeConnectOnboardingScreenState();
}

class _StripeConnectOnboardingScreenState extends State<StripeConnectOnboardingScreen> {
  bool _isLoading = true;
  bool _isCreatingAccount = false;
  bool _isCreatingLink = false;
  String? _onboardingUrl;
  Map<String, dynamic>? _accountStatus;
  WebViewController? _webViewController;

  @override
  void initState() {
    super.initState();
    _checkAccountStatus();
  }

  Future<void> _checkAccountStatus() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final status = await StripeService.getStripeConnectAccountStatus(
        facilityId: widget.facility.id,
      );

      setState(() {
        _accountStatus = status;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error checking status: ${ErrorMessageHelper.getUserFriendlyMessage(e)}')),
        );
      }
    }
  }

  Future<void> _createConnectAccount() async {
    setState(() {
      _isCreatingAccount = true;
    });

    try {
      await StripeService.createStripeConnectAccount(
        facilityId: widget.facility.id,
      );

      // After creating account, create the onboarding link
      await _createOnboardingLink();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error creating account: ${ErrorMessageHelper.getUserFriendlyMessage(e)}')),
        );
        setState(() {
          _isCreatingAccount = false;
        });
      }
    }
  }

  Future<void> _createOnboardingLink() async {
    setState(() {
      _isCreatingLink = true;
    });

    try {
      final url = await StripeService.createStripeConnectAccountLink(
        facilityId: widget.facility.id,
      );

      setState(() {
        _onboardingUrl = url;
        _isCreatingLink = false;
        _isCreatingAccount = false;
      });

      // Show onboarding webview
      _showOnboardingWebView(url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error creating onboarding link: ${ErrorMessageHelper.getUserFriendlyMessage(e)}')),
        );
        setState(() {
          _isCreatingLink = false;
          _isCreatingAccount = false;
        });
      }
    }
  }

  void _showOnboardingWebView(String url) {
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
                  color: AppTheme.primaryBlueDark,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(8),
                    topRight: Radius.circular(8),
                  ),
                ),
                child: Row(
                  children: [
                    const Text(
                      'Stripe Connect Onboarding',
                      style: TextStyle(
                        color: AppTheme.textOnDark,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(Icons.close, color: AppTheme.textOnDark),
                      onPressed: () {
                        Navigator.of(context).pop();
                        _checkAccountStatus(); // Refresh status
                      },
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
                          // Check if we're on return/refresh page
                          if (url.contains('stripe-connect/return') || url.contains('stripe-connect/refresh')) {
                            // Close dialog and refresh status
                            Future.delayed(const Duration(seconds: 2), () {
                              if (mounted) {
                                Navigator.of(context).pop();
                                _checkAccountStatus();
                              }
                            });
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

  @override
  Widget build(BuildContext context) {
    return ModernPageWrapper(
      currentRoute: '/settings',
      title: 'Stripe Connect Setup',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : KeyboardScrollable(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Info Card
                  Card(
                    elevation: 4,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.account_balance_wallet, color: AppTheme.primaryBlueDark),
                              const SizedBox(width: 12),
                              const Text(
                                'Connect Your Stripe Account',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Connect your Stripe account to receive tenant rent payments directly. '
                            'All payments go directly to your Stripe account with 0% platform fees.',
                            style: TextStyle(fontSize: 14),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppTheme.primaryBlue.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Benefits:',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                SizedBox(height: 8),
                                Text('• 0% platform fees - keep 100% of payments'),
                                Text('• Direct deposits to your bank account'),
                                Text('• Professional payment processing'),
                                Text('• Secure PCI-compliant transactions'),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Status Card
                  if (_accountStatus != null) ...[
                    Card(
                      elevation: 4,
                      color: _accountStatus!['onboardingComplete'] == true
                          ? AppTheme.success.withOpacity(0.1)
                          : AppTheme.warning.withOpacity(0.1),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  _accountStatus!['onboardingComplete'] == true
                                      ? Icons.check_circle
                                      : Icons.pending,
                                  color: _accountStatus!['onboardingComplete'] == true
                                      ? AppTheme.success
                                      : AppTheme.warning,
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  _accountStatus!['onboardingComplete'] == true
                                      ? 'Account Connected'
                                      : 'Onboarding Incomplete',
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            if (_accountStatus!['connected'] == true) ...[
                              const SizedBox(height: 12),
                              _buildStatusRow('Account ID', _accountStatus!['accountId'] ?? 'N/A'),
                              _buildStatusRow('Charges Enabled', _accountStatus!['chargesEnabled'] == true ? 'Yes' : 'No'),
                              _buildStatusRow('Payouts Enabled', _accountStatus!['payoutsEnabled'] == true ? 'Yes' : 'No'),
                              _buildStatusRow('Details Submitted', _accountStatus!['detailsSubmitted'] == true ? 'Yes' : 'No'),
                              if (_accountStatus!['email'] != null)
                                _buildStatusRow('Email', _accountStatus!['email']),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Action Buttons
                  if (_accountStatus == null || _accountStatus!['connected'] != true) ...[
                    // Create Account Button
                    ElevatedButton.icon(
                      onPressed: _isCreatingAccount ? null : _createConnectAccount,
                      icon: _isCreatingAccount
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.add),
                      label: Text(_isCreatingAccount
                          ? 'Creating Account...'
                          : 'Connect Stripe Account'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.success,
                        foregroundColor: AppTheme.textOnDark,
                        padding: const EdgeInsets.all(16),
                      ),
                    ),
                  ] else if (_accountStatus!['onboardingComplete'] != true) ...[
                    // Continue Onboarding Button
                    ElevatedButton.icon(
                      onPressed: _isCreatingLink ? null : _createOnboardingLink,
                      icon: _isCreatingLink
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.arrow_forward),
                      label: Text(_isCreatingLink
                          ? 'Creating Link...'
                          : 'Continue Onboarding'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryBlue,
                        foregroundColor: AppTheme.textOnDark,
                        padding: const EdgeInsets.all(16),
                      ),
                    ),
                  ] else ...[
                    // Already Connected
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.success.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppTheme.success.withOpacity(0.3)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.check_circle, color: AppTheme.success),
                              SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Your Stripe account is connected and ready to receive payments!',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: AppTheme.success,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (_accountStatus!['accountId'] != null)
                            Text(
                              'Account ID: ${_accountStatus!['accountId']}',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppTheme.textSecondary,
                                fontFamily: 'monospace',
                              ),
                            ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Icon(
                                _accountStatus!['chargesEnabled'] == true
                                    ? Icons.check_circle_outline
                                    : Icons.error_outline,
                                size: 16,
                                color: _accountStatus!['chargesEnabled'] == true
                                    ? AppTheme.success
                                    : AppTheme.error,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Charges: ${_accountStatus!['chargesEnabled'] == true ? 'Enabled' : 'Disabled'}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Icon(
                                _accountStatus!['payoutsEnabled'] == true
                                    ? Icons.check_circle_outline
                                    : Icons.error_outline,
                                size: 16,
                                color: _accountStatus!['payoutsEnabled'] == true
                                    ? AppTheme.success
                                    : AppTheme.error,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Payouts: ${_accountStatus!['payoutsEnabled'] == true ? 'Enabled' : 'Disabled'}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Reconnect option (if needed)
                    OutlinedButton.icon(
                      onPressed: () {
                        // Allow reconnecting if account was disconnected
                        _createOnboardingLink();
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reconnect or Update Account'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.all(12),
                      ),
                    ),
                  ],

                  const SizedBox(height: 16),

                  // Refresh Button
                  OutlinedButton.icon(
                    onPressed: _checkAccountStatus,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh Status'),
                  ),
                ],
              ),
            ),
          ),
    );
  }

  Widget _buildStatusRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: AppTheme.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}

