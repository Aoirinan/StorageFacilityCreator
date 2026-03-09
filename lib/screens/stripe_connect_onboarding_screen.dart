import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/providers/payment_provider.dart';
import 'package:sfcapp/services/modern_navigation_service.dart';
import 'package:sfcapp/services/stripe_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/utils/error_message_helper.dart';
import 'package:sfcapp/widgets/keyboard_scrollable.dart';
import 'package:sfcapp/utils/open_url_stub.dart' if (dart.library.html) 'package:sfcapp/utils/open_url_web.dart' as open_url;

/// Screen for facility owners to connect their Stripe account
/// This enables them to receive tenant rent payments directly
class StripeConnectOnboardingScreen extends ConsumerStatefulWidget {
  final FacilityModel facility;

  const StripeConnectOnboardingScreen({
    super.key,
    required this.facility,
  });

  @override
  ConsumerState<StripeConnectOnboardingScreen> createState() => _StripeConnectOnboardingScreenState();
}

class _StripeConnectOnboardingScreenState extends ConsumerState<StripeConnectOnboardingScreen> {
  bool _isLoading = false; // Start as false so UI shows immediately
  bool _isCreatingAccount = false;
  bool _isCreatingLink = false;
  String? _onboardingUrl;
  Map<String, dynamic>? _accountStatus;
  WebViewController? _webViewController;
  /// Facility we're showing status for; stays in sync with the global facility dropdown.
  String _displayFacilityId = '';

  @override
  void initState() {
    super.initState();
    _displayFacilityId = widget.facility.id;
    // Don't block UI on initial load - check status in background
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAccountStatus();
    });
  }

  Future<void> _checkAccountStatus({String? facilityId}) async {
    final id = facilityId ?? _displayFacilityId;
    if (id.isEmpty) return;
    // Show loading indicator only if we don't have status yet
    final wasLoading = _isLoading;
    if (_accountStatus == null && !_isLoading) {
      setState(() {
        _isLoading = true;
      });
    }

    try {
      final status = await StripeService.getStripeConnectAccountStatus(
        facilityId: id,
      );

      if (mounted && id == _displayFacilityId) {
        setState(() {
          _accountStatus = status;
          _isLoading = false;
        });
        ref.invalidate(stripeConnectStatusProvider(id));
      }
    } catch (e) {
      if (mounted) {
        // Always clear loading, even on error
        setState(() {
          _isLoading = false;
        });
        
        // Only show error snackbar if this was a manual refresh (user clicked button)
        // Don't spam errors on initial background load
        final errorMessage = ErrorMessageHelper.getUserFriendlyMessage(e);
        // Only show error if it's not a timeout and user manually triggered it
        if (errorMessage.isNotEmpty && 
            !errorMessage.contains('timed out') && 
            !errorMessage.contains('Request timed out')) {
          // Only show snackbar if this wasn't the initial silent load
          if (wasLoading || _accountStatus != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error checking status: $errorMessage'),
                backgroundColor: AppTheme.error,
                duration: const Duration(seconds: 5),
              ),
            );
          }
        }
      }
    } finally {
      // Ensure loading is always cleared - critical for preventing grey screen
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _createConnectAccount() async {
    setState(() {
      _isCreatingAccount = true;
    });

    try {
      await StripeService.createStripeConnectAccount(
        facilityId: _displayFacilityId,
      );

      // After creating account, create the onboarding link
      await _createOnboardingLink();
    } catch (e) {
      if (mounted) {
        final errorMessage = ErrorMessageHelper.getUserFriendlyMessage(e);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage.isNotEmpty 
                ? 'Error creating account: $errorMessage'
                : 'Failed to create Stripe account. Please try again.'),
            backgroundColor: AppTheme.error,
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Retry',
              textColor: AppTheme.textOnDark,
              onPressed: () => _createConnectAccount(),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
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
        facilityId: _displayFacilityId,
      );

      if (mounted) {
        setState(() {
          _onboardingUrl = url;
          _isCreatingLink = false;
          _isCreatingAccount = false;
        });

        // Open URL with window.open, fallback to same tab if popup blocked
        _openOnboardingUrl(url);
      }
    } catch (e) {
      if (mounted) {
        final errorMessage = ErrorMessageHelper.getUserFriendlyMessage(e);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage.isNotEmpty 
                ? 'Error creating onboarding link: $errorMessage'
                : 'Failed to create onboarding link. Please try again.'),
            backgroundColor: AppTheme.error,
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Retry',
              textColor: AppTheme.textOnDark,
              onPressed: () => _createOnboardingLink(),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCreatingLink = false;
          _isCreatingAccount = false;
        });
      }
    }
  }

  void _openOnboardingUrl(String url) {
    if (kIsWeb) {
      try {
        open_url.openUrlInBrowserWeb(url);
      } catch (e) {
        // Fallback: show webview dialog if opening in browser fails
        if (mounted) {
          _showOnboardingWebView(url);
        }
      }
    } else {
      _showOnboardingWebView(url);
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
    // When user changes the facility dropdown (in sidebar/top bar), show that facility's Stripe status
    ref.listen(activeFacilityIdProvider, (previous, next) {
      final newId = next.whenOrNull(data: (d) => d);
      if (newId != null && newId != _displayFacilityId) {
        setState(() {
          _displayFacilityId = newId;
          _accountStatus = null;
        });
        _checkAccountStatus(facilityId: newId);
      }
    });

    // Note: No ModernPageWrapper needed - already inside AppShell which provides sidebar
    return SizedBox.expand(
      child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : KeyboardScrollable(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Facility context card
                  Card(
                    elevation: 2,
                    color: AppTheme.surface,
                    shape: RoundedRectangleBorder(
                      side: const BorderSide(color: AppTheme.borderLight),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: Row(
                        children: [
                          Icon(Icons.business_outlined, color: AppTheme.primaryBlue, size: 20),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text(
                                  'Viewing facility',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                                Text(
                                  widget.facility.name,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Info Card
                  Card(
                    elevation: 2,
                    color: AppTheme.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: const BorderSide(color: AppTheme.borderLight),
                    ),
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
                                  color: AppTheme.textPrimary,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Connect your Stripe account to receive tenant rent payments directly. '
                            'All payments go directly to your Stripe account with 0% platform fees.',
                            style: TextStyle(fontSize: 14, color: AppTheme.textPrimary),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppTheme.surface,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppTheme.borderLight),
                            ),
                            child: const Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Benefits:',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                    color: AppTheme.textPrimary,
                                  ),
                                ),
                                SizedBox(height: 8),
                                Text(
                                  '• 0% platform fees - keep 100% of payments',
                                  style: TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                                ),
                                Text(
                                  '• Direct deposits to your bank account',
                                  style: TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                                ),
                                Text(
                                  '• Professional payment processing',
                                  style: TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                                ),
                                Text(
                                  '• Secure PCI-compliant transactions',
                                  style: TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                                ),
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
                      elevation: 2,
                      color: AppTheme.surface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: BorderSide(
                          color: _accountStatus!['onboardingComplete'] == true
                              ? AppTheme.success
                              : AppTheme.primaryBlue,
                          width: 1,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: (_accountStatus!['onboardingComplete'] == true
                                            ? AppTheme.success
                                            : AppTheme.primaryBlue)
                                        .withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _accountStatus!['onboardingComplete'] == true
                                            ? Icons.check_circle
                                            : Icons.info_outline,
                                        size: 16,
                                        color: _accountStatus!['onboardingComplete'] == true
                                            ? AppTheme.success
                                            : AppTheme.primaryBlue,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        _accountStatus!['onboardingComplete'] == true
                                            ? 'Account Connected'
                                            : 'Onboarding Incomplete',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: _accountStatus!['onboardingComplete'] == true
                                              ? AppTheme.success
                                              : AppTheme.primaryBlue,
                                        ),
                                      ),
                                    ],
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
                      onPressed: (_isLoading || _isCreatingAccount || _isCreatingLink) 
                          ? null 
                          : _createConnectAccount,
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
                      onPressed: (_isLoading || _isCreatingAccount || _isCreatingLink) 
                          ? null 
                          : _createOnboardingLink,
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
                        color: AppTheme.surface,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppTheme.success, width: 1),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.04),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
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
                      onPressed: (_isLoading || _isCreatingAccount || _isCreatingLink) 
                          ? null 
                          : () {
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
                    onPressed: (_isLoading || _isCreatingAccount || _isCreatingLink) 
                        ? null 
                        : _checkAccountStatus,
                    icon: _isLoading 
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    label: Text(_isLoading ? 'Refreshing...' : 'Refresh Status'),
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
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary, // Dark text for readability
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: AppTheme.textPrimary, // Dark text instead of light grey
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

