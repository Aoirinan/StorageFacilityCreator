import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:go_router/go_router.dart';
import '../services/facility_creator_account_service.dart';
import '../services/superadmin_service.dart';
import '../services/stripe_service.dart';
import '../models/facility_creator_account_model.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';

/// Test screen for subscription checkout and payment testing
class SubscriptionTestScreen extends StatefulWidget {
  final bool requireSubscriptionChoice;
  final String? message;
  
  const SubscriptionTestScreen({
    super.key,
    this.requireSubscriptionChoice = false,
    this.message,
  });

  @override
  State<SubscriptionTestScreen> createState() => _SubscriptionTestScreenState();
}

class _SubscriptionTestScreenState extends State<SubscriptionTestScreen> {
  FacilityCreatorAccountModel? _account;
  bool _isLoading = true;
  bool _isCreatingCheckout = false;
  bool _isStartingTrial = false;
  String? _checkoutUrl;
  WebViewController? _webViewController;

  @override
  void initState() {
    super.initState();
    _loadAccount();
  }

  Future<void> _loadAccount() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw Exception('Not authenticated');
      }

      final account = await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
      
      setState(() {
        _account = account;
        _isLoading = false;
      });

      // Listen for account updates (e.g., after webhook processes payment)
      FacilityCreatorAccountService.getAccountStream(account.accountId).listen((updatedAccount) {
        if (updatedAccount != null && mounted) {
          setState(() {
            _account = updatedAccount;
          });
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading account: $e')),
        );
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _createSubscriptionCheckout() async {
    if (_account == null) {
      if (kDebugMode) print('❌ Cannot create checkout: Account is null');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Account not loaded. Please refresh the page.'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    setState(() {
      _isCreatingCheckout = true;
    });

    try {
      if (kDebugMode) {
        print('🔄 Starting subscription checkout creation...');
        print('📋 Account ID: ${_account!.accountId}');
      }

      final user = FirebaseAuth.instance.currentUser;
      if (user?.email == null) {
        throw Exception('User email not available');
      }

      if (kDebugMode) print('📧 Customer Email: ${user!.email}');

      final checkoutUrl = await StripeService.createSubscriptionCheckout(
        accountId: _account!.accountId,
        customerEmail: user!.email!,
        successUrl: 'https://storage-facility-creator.web.app/subscription/success?session_id={CHECKOUT_SESSION_ID}',
        cancelUrl: 'https://storage-facility-creator.web.app/subscription/cancel',
      );

      if (kDebugMode) {
        print('✅ Checkout URL received: $checkoutUrl');
      }

      setState(() {
        _checkoutUrl = checkoutUrl;
        _isCreatingCheckout = false;
      });

      // On web, use url_launcher; on mobile, use WebView
      if (kIsWeb) {
        if (kDebugMode) print('🌐 Opening checkout in new browser tab (web)...');
        // For web, open in new tab/window
        final uri = Uri.parse(checkoutUrl);
        try {
          final canLaunch = await canLaunchUrl(uri);
          if (kDebugMode) print('🔍 Can launch URL: $canLaunch');
          
          if (canLaunch) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
            if (kDebugMode) print('✅ Checkout opened in new tab');
            
            // Show success message
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Opening Stripe checkout in new tab...'),
                  backgroundColor: AppTheme.success,
                  duration: Duration(seconds: 3),
                ),
              );
            }
          } else {
            throw Exception('Browser blocked opening checkout URL. Please allow popups.');
          }
        } catch (e) {
          if (kDebugMode) print('❌ Error launching URL: $e');
          // Fallback: show URL to user
          if (mounted) {
            showDialog(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Checkout URL'),
                content: SelectableText(checkoutUrl),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ],
              ),
            );
          }
          throw Exception('Could not open checkout URL automatically. URL: $checkoutUrl');
        }
      } else {
        if (kDebugMode) print('📱 Opening checkout in WebView (mobile)...');
        // Open checkout in webview (for mobile)
        _showCheckoutWebView(checkoutUrl);
      }
    } catch (e) {
      if (mounted) {
        // Show detailed error in debug mode, user-friendly in production
        final errorMessage = kDebugMode 
            ? 'Error creating checkout: $e' 
            : 'Failed to create checkout. Please try again or check your connection.';
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: AppTheme.error,
            duration: const Duration(seconds: 5),
          ),
        );
        
        if (kDebugMode) {
          print('❌ Subscription checkout error: $e');
          print('Stack trace: ${StackTrace.current}');
        }
        
        setState(() {
          _isCreatingCheckout = false;
        });
      }
    }
  }

  Future<void> _startTrial() async {
    // Ensure account exists before starting trial
    if (_account == null) {
      try {
        if (kDebugMode) {
          print('⚠️ Account is null, attempting to create/get account...');
        }
        final account = await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
        setState(() {
          _account = account;
        });
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error: Could not create account. Please try again: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
        return;
      }
    }

    setState(() {
      _isStartingTrial = true;
    });

    try {
      if (kDebugMode) {
        print('🔄 Starting 30-day trial for account: ${_account!.accountId}');
      }

      await StripeService.startTrial(accountId: _account!.accountId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ 30-day trial started successfully!'),
            backgroundColor: AppTheme.success,
            duration: Duration(seconds: 3),
          ),
        );

        // Reload account to show updated status
        await _loadAccount();

        // If subscription was required, allow navigation away
        if (widget.requireSubscriptionChoice && mounted) {
          // Show success and allow them to continue
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Trial Started!'),
              content: const Text(
                'Your 30-day trial has started. You now have full access to all features including emails, texts, and more!',
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop(); // Close dialog
                    Navigator.of(context).pop(); // Go back to home
                  },
                  child: const Text('Get Started'),
                ),
              ],
            ),
          );
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error starting trial: $e');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error starting trial: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isStartingTrial = false;
        });
      }
    }
  }

  Future<void> _openCustomerPortal() async {
    if (_account == null) return;

    try {
      final portalUrl = await StripeService.createCustomerPortalSession(
        accountId: _account!.accountId,
        returnUrl: 'https://storage-facility-creator.web.app/subscription/manage',
      );

      // Open portal in webview
      _showCheckoutWebView(portalUrl);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error opening portal: $e')),
        );
      }
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
              // Header with close button
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
                      'Stripe Checkout',
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
                        // Reload account to check for updates
                        _loadAccount();
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
                          // Check if we're on success/cancel page
                          if (url.contains('success') || url.contains('cancel')) {
                            // Close dialog and reload account
                            Future.delayed(const Duration(seconds: 2), () {
                              if (mounted) {
                                Navigator.of(context).pop();
                                _loadAccount();
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
    return WillPopScope(
      onWillPop: () async {
        // Prevent going back if subscription choice is required
        // Superadmins bypass this restriction
        if (widget.requireSubscriptionChoice && 
            _account != null && 
            !_account!.isSubscriptionActive &&
            !SuperAdminService.isSuperAdmin()) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please choose a subscription option to continue'),
              backgroundColor: AppTheme.warning,
              duration: Duration(seconds: 3),
            ),
          );
          return false;
        }
        return true;
      },
      child: ModernPageWrapper(
        currentRoute: '/subscription',
        title: widget.requireSubscriptionChoice 
            ? 'Choose Subscription' 
            : 'Subscription & Payment Test',
        onNavigate: (route) {
          ModernNavigationService.navigateToRoute(context, route);
        },
        child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _account == null
              ? const Center(child: Text('No account found'))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Account Info Card
                      Card(
                        elevation: 4,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Account Information',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 16),
                              _buildInfoRow('Account ID', _account!.accountId),
                              _buildInfoRow('Owner Email', _account!.ownerEmail),
                              _buildInfoRow('Owner Name', _account!.ownerName),
                              _buildInfoRow(
                                'Facilities',
                                '${_account!.facilityIds.length}',
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Subscription Status Card
                      Card(
                        elevation: 4,
                        color: _getStatusColor(_account!.subscriptionStatus),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Subscription Status',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 16),
                              _buildInfoRow(
                                'Status',
                                _account!.subscriptionStatus.displayName,
                              ),
                              if (_account!.stripeCustomerId != null)
                                _buildInfoRow(
                                  'Stripe Customer',
                                  _account!.stripeCustomerId!,
                                ),
                              if (_account!.stripeSubscriptionId != null)
                                _buildInfoRow(
                                  'Stripe Subscription',
                                  _account!.stripeSubscriptionId!,
                                ),
                              if (_account!.subscriptionCurrentPeriodStart != null)
                                _buildInfoRow(
                                  'Current Period Start',
                                  _formatDate(_account!.subscriptionCurrentPeriodStart!),
                                ),
                              if (_account!.subscriptionCurrentPeriodEnd != null)
                                _buildInfoRow(
                                  'Current Period End',
                                  _formatDate(_account!.subscriptionCurrentPeriodEnd!),
                                ),
                              if (_account!.daysUntilExpiration != null)
                                _buildInfoRow(
                                  'Days Until Expiration',
                                  '${_account!.daysUntilExpiration}',
                                ),
                              // Trial expiration info
                              if (_account!.hasTrial && _account!.daysUntilTrialExpiration != null)
                                _buildInfoRow(
                                  'Trial Days Remaining',
                                  '${_account!.daysUntilTrialExpiration}',
                                ),
                              if (_account!.isTrialExpired)
                                const Padding(
                                  padding: EdgeInsets.only(top: 8),
                                  child: Text(
                                    '⚠️ Trial has expired. Please subscribe to continue.',
                                    style: TextStyle(
                                      color: AppTheme.error,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                )
                              else if (_account!.isTrialExpiringSoon)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(
                                    '⚠️ Trial expiring in ${_account!.daysUntilTrialExpiration} days. Subscribe to continue.',
                                    style: const TextStyle(
                                      color: AppTheme.warning,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              // Grace period info
                              if (_account!.isSubscriptionPastDue && _account!.daysRemainingInGracePeriod != null)
                                _buildInfoRow(
                                  'Grace Period Days Remaining',
                                  '${_account!.daysRemainingInGracePeriod}',
                                ),
                              if (_account!.isGracePeriodExpired)
                                const Padding(
                                  padding: EdgeInsets.only(top: 8),
                                  child: Text(
                                    '⚠️ Grace period expired. Please reactivate your subscription.',
                                    style: TextStyle(
                                      color: AppTheme.error,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                )
                              else if (_account!.isSubscriptionPastDue && _account!.canAccessPlatform)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(
                                    '⚠️ Payment past due. ${_account!.daysRemainingInGracePeriod} days remaining in grace period.',
                                    style: const TextStyle(
                                      color: AppTheme.warning,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              if (_account!.subscriptionCancelAtPeriodEnd)
                                const Padding(
                                  padding: EdgeInsets.only(top: 8),
                                  child: Text(
                                    '⚠️ Subscription will cancel at period end',
                                    style: TextStyle(
                                      color: AppTheme.warning,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Required Subscription Choice Banner (if needed)
                      // Superadmins bypass subscription requirements
                      if (widget.requireSubscriptionChoice && 
                          _account != null && 
                          !_account!.isSubscriptionActive &&
                          !SuperAdminService.isSuperAdmin())
                        Card(
                          elevation: 4,
                          color: AppTheme.warning.withOpacity(0.1),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.warning, color: AppTheme.warning),
                                    const SizedBox(width: 8),
                                    const Text(
                                      'Subscription Required',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: AppTheme.warning,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  widget.message ?? 
                                  'To use your facility, you must choose either a 30-day trial or subscribe now. '
                                  'All features including emails, texts, and reports are available with either option.',
                                  style: const TextStyle(fontSize: 14),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (widget.requireSubscriptionChoice && 
                          _account != null && 
                          !_account!.isSubscriptionActive)
                        const SizedBox(height: 16),

                      // Custom Message (if provided)
                      if (widget.message != null) ...[
                        Card(
                          elevation: 4,
                          color: AppTheme.primaryBlue.withOpacity(0.1),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                Icon(Icons.info_outline, color: AppTheme.primaryBlue),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    widget.message!,
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],

                      // Actions Card
                      Card(
                        elevation: 4,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                widget.requireSubscriptionChoice && 
                                _account != null && 
                                !_account!.isSubscriptionActive
                                    ? 'Choose Your Subscription'
                                    : 'Subscription Actions',
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 16),
                              
                              // Start Trial Button (show if no active subscription)
                              if (_account != null && !_account!.isSubscriptionActive) ...[
                                ElevatedButton.icon(
                                  onPressed: (_isStartingTrial || _isCreatingCheckout) ? null : _startTrial,
                                  icon: _isStartingTrial
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(strokeWidth: 2),
                                        )
                                      : const Icon(Icons.star),
                                  label: Text(_isStartingTrial
                                      ? 'Starting Trial...'
                                      : 'Start 30-Day Free Trial'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppTheme.primaryBlue,
                                    foregroundColor: AppTheme.textOnDark,
                                    padding: const EdgeInsets.all(16),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  '✓ Basic features unlocked\n'
                                  '✓ No credit card required\n'
                                  '✓ DNR System (Premium) not included',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textTertiary,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 16),
                                const Row(
                                  children: [
                                    Expanded(child: Divider()),
                                    Text(' OR ', style: TextStyle(color: AppTheme.textTertiary)),
                                    Expanded(child: Divider()),
                                  ],
                                ),
                                const SizedBox(height: 16),
                              ],
                              
                              // Subscribe Button
                              ElevatedButton.icon(
                                onPressed: (_isCreatingCheckout || _isStartingTrial) ? null : _createSubscriptionCheckout,
                                icon: _isCreatingCheckout
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Icon(Icons.payment),
                                label: Text(_isCreatingCheckout
                                    ? 'Creating Checkout...'
                                    : 'Subscribe Now (\$75/month + \$75 per additional facility)'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.success,
                                  foregroundColor: AppTheme.textOnDark,
                                  padding: const EdgeInsets.all(16),
                                ),
                              ),
                              const SizedBox(height: 12),

                              // Customer Portal Button (Manage/Cancel Subscription)
                              if (_account!.stripeSubscriptionId != null) ...[
                                ElevatedButton.icon(
                                  onPressed: _openCustomerPortal,
                                  icon: const Icon(Icons.settings),
                                  label: const Text('Manage Subscription'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppTheme.primaryBlue,
                                    foregroundColor: AppTheme.textOnDark,
                                    padding: const EdgeInsets.all(16),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                OutlinedButton.icon(
                                  onPressed: _openCustomerPortal,
                                  icon: const Icon(Icons.cancel_outlined),
                                  label: const Text('Cancel Subscription'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: AppTheme.error,
                                    padding: const EdgeInsets.all(16),
                                    side: BorderSide(color: AppTheme.error),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Manage Subscription opens Stripe Customer Portal where you can:\n'
                                  '• Cancel your subscription\n'
                                  '• Update payment method\n'
                                  '• View invoices\n'
                                  '• Reactivate cancelled subscription',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textTertiary,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                              
                              const SizedBox(height: 12),
                              
                              // Refresh Button
                              OutlinedButton.icon(
                                onPressed: _loadAccount,
                                icon: const Icon(Icons.refresh),
                                label: const Text('Refresh Status'),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Pricing & Facilities Info (only show if has subscription)
                      if (_account != null && _account!.hasActiveSubscription) ...[
                        Card(
                          elevation: 4,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Current Plan',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                _buildInfoRow('Facilities', '${_account!.facilityIds.length}'),
                                _buildInfoRow(
                                  'Monthly Cost',
                                  '\$${_calculateMonthlyCost()}/month',
                                ),
                                const SizedBox(height: 12),
                                const Divider(),
                                const SizedBox(height: 12),
                                const Text(
                                  'Pricing',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text('• Base Plan: \$75/month (first facility)'),
                                const Text('• Additional Facilities: \$75/month each'),
                                const SizedBox(height: 16),
                                const Divider(),
                                const SizedBox(height: 12),
                                const Text(
                                  'Payment Terms',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  '• Billing: Monthly recurring subscription\n'
                                  '• Cancellation: Cancel anytime from your account\n'
                                  '• Refunds: Prorated refunds for unused time\n'
                                  '• Changes: Price updates with 30 days notice',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ] else if (_account != null && !_account!.hasActiveSubscription) ...[
                        // Pricing info for non-subscribers
                        Card(
                          elevation: 4,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Pricing',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                const Text('• Base Plan: \$75/month (first facility)'),
                                const Text('• Additional Facilities: \$75/month each'),
                                const SizedBox(height: 16),
                                const Divider(),
                                const SizedBox(height: 12),
                                const Text(
                                  'Payment Terms',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  '• Billing: Monthly recurring subscription\n'
                                  '• Cancellation: Cancel anytime from your account\n'
                                  '• Refunds: Prorated refunds for unused time\n'
                                  '• Changes: Price updates with 30 days notice',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                    ],
                  ),
                ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
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

  Color? _getStatusColor(SubscriptionStatus status) {
    switch (status) {
      case SubscriptionStatus.active:
        return AppTheme.success.withOpacity(0.1);
      case SubscriptionStatus.trialing:
        return AppTheme.primaryBlue.withOpacity(0.1);
      case SubscriptionStatus.pastDue:
        return AppTheme.warning.withOpacity(0.1);
      case SubscriptionStatus.cancelled:
        return AppTheme.error.withOpacity(0.1);
      default:
        return AppTheme.textTertiary.withOpacity(0.1);
    }
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }

  double _calculateMonthlyCost() {
    if (_account == null) return 0;
    final facilityCount = _account!.facilityIds.length;
    // Always show at least $75 (base plan), even with 0 facilities
    if (facilityCount == 0) return 75.0;
    return 75.0 * facilityCount; // $75 per facility
  }
}

