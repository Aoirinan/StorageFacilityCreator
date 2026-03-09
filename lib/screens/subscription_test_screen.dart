import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/services/facility_creator_account_service.dart';
import 'package:sfcapp/services/facility_service.dart';
import 'package:sfcapp/services/modern_navigation_service.dart';
import 'package:sfcapp/services/stripe_service.dart';
import 'package:sfcapp/services/superadmin_service.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/utils/error_message_helper.dart';

/// Test screen for subscription checkout and payment testing
class SubscriptionTestScreen extends ConsumerStatefulWidget {
  final bool requireSubscriptionChoice;
  final String? message;
  /// When true, show a reminder dialog that trial has expired (e.g. after redirect from guard).
  final bool showTrialExpiredDialog;
  
  const SubscriptionTestScreen({
    super.key,
    this.requireSubscriptionChoice = false,
    this.message,
    this.showTrialExpiredDialog = false,
  });

  @override
  ConsumerState<SubscriptionTestScreen> createState() => _SubscriptionTestScreenState();
}

class _SubscriptionTestScreenState extends ConsumerState<SubscriptionTestScreen> {
  FacilityCreatorAccountModel? _account;
  int? _actualFacilityCount; // Real count from facilities list (avoids orphaned facilityIds)
  List<FacilityModel> _subscribedFacilities = [];
  bool _isLoading = true;
  bool _isCreatingCheckout = false;
  bool _isStartingTrial = false;
  bool _isCancelling = false;
  bool _isRemovingFacility = false;
  String? _checkoutUrl;
  WebViewController? _webViewController;
  bool _hasShownTrialExpiredDialog = false;

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

      // Server-side reconcile (source of truth): fix facilityIds + Stripe from actual active facilities.
      try {
        final result = await FacilityCreatorAccountService.callReconcileAccountFacilityIds();
        if (result != null && mounted) {
          final count = (result['facilityCount'] as num?)?.toInt() ?? account.facilityIds.length;
          final updated = await FacilityCreatorAccountService.getAccount(account.accountId);
          setState(() {
            _account = updated ?? _account;
            _actualFacilityCount = count;
          });
        }
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ Server reconcile failed, falling back to client: $e');
        }
        // If CORS/network error on custom domain, show hint to add domain to Firebase authorized domains
        final errStr = e.toString().toLowerCase();
        if (mounted && (errStr.contains('cors') || errStr.contains('failed') || errStr.contains('err_'))) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Connection issue: If using storagefacilitycreator.com, add it to Firebase Console → Authentication → Settings → Authorized domains.',
              ),
              backgroundColor: AppTheme.info,
              duration: const Duration(seconds: 6),
            ),
          );
        }
        // Fallback: client-side - only reconcile facilities linked to account (respects "removed" state)
        try {
          final facilities = await FacilityService.getUserFacilities(
            includeArchived: false,
            forceRefresh: true,
          );
          final linkedIds = facilities
              .where((f) => f.facilityCreatorAccountId == account.accountId)
              .map((f) => f.id)
              .toList();
          try {
            await FacilityCreatorAccountService.reconcileFacilityIds(
              accountId: account.accountId,
              actualFacilityIds: linkedIds,
            );
          } catch (_) {}
          if (mounted) {
            final updated = await FacilityCreatorAccountService.getAccount(account.accountId);
            setState(() {
              _account = updated ?? _account;
              _actualFacilityCount = linkedIds.length;
            });
          }
        } catch (e2) {
          if (kDebugMode) {
            print('⚠️ Could not load facility count: $e2');
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Could not sync facility count. ${ErrorMessageHelper.getUserFriendlyMessage(e2)}',
                ),
                backgroundColor: AppTheme.warning,
                duration: const Duration(seconds: 4),
              ),
            );
          }
        }
      }

      // Load subscribed facilities for cancel-per-facility UI
      if (account.facilityIds.isNotEmpty) {
        try {
          final allFacilities = await FacilityService.getUserFacilities(
            includeArchived: false,
            forceRefresh: true,
          );
          final ids = account.facilityIds.toSet();
          final subscribed = allFacilities.where((f) => ids.contains(f.id)).toList();
          if (mounted) {
            setState(() {
              _subscribedFacilities = subscribed;
            });
          }
        } catch (e) {
          if (kDebugMode) {
            print('⚠️ Could not load facilities for cancel UI: $e');
          }
        }
      }

      // Listen for account updates (e.g., after webhook processes payment)
      FacilityCreatorAccountService.getAccountStream(account.accountId).listen((updatedAccount) {
        if (updatedAccount != null && mounted) {
          setState(() {
            _account = updatedAccount;
          });
        }
      });

      // Show trial-expired reminder dialog when redirected or when account is expired
      if (mounted &&
          !_hasShownTrialExpiredDialog &&
          (widget.showTrialExpiredDialog || (account.hasTrial && account.isTrialExpired))) {
        _hasShownTrialExpiredDialog = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _showTrialExpiredDialog(context);
        });
      }
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

  void _showTrialExpiredDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: AppTheme.warning, size: 48),
        title: const Text('Trial Expired'),
        content: const Text(
          'Your trial has expired. Please subscribe to continue using the app. '
          'All features are locked until you subscribe.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Dismiss'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _createSubscriptionCheckout();
            },
            child: const Text('Subscribe Now'),
          ),
        ],
      ),
    );
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
    // Per-facility: need to select which facility to subscribe
    if (_subscribedFacilities.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Create a facility first, then subscribe it below.'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }
    setState(() => _isCreatingCheckout = true);

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

      // Use legacy account-level checkout (single subscription for all facilities)
      final checkoutResult = await StripeService.createSubscriptionCheckout(
        accountId: _account!.accountId,
        customerEmail: user!.email!,
        successUrl: 'https://storage-facility-creator.web.app/subscription/success?session_id={CHECKOUT_SESSION_ID}',
        cancelUrl: 'https://storage-facility-creator.web.app/subscription/cancel',
      );

      if (!mounted) return;
      if (checkoutResult.subscriptionUpdated) {
        setState(() => _isCreatingCheckout = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(checkoutResult.message ?? 'Subscription updated to include your new facility.'),
            backgroundColor: AppTheme.success,
            duration: const Duration(seconds: 5),
          ),
        );
        _loadAccount();
        return;
      }

      final checkoutUrl = checkoutResult.checkoutUrl!;
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

  /// Subscribe one facility with its own card (per-facility model).
  Future<void> _createFacilitySubscriptionCheckout(FacilityModel facility) async {
    if (_account == null || _isCreatingCheckout) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user?.email == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User email not available')));
      return;
    }
    setState(() => _isCreatingCheckout = true);
    try {
      final result = await StripeService.createFacilitySubscriptionCheckout(
        accountId: _account!.accountId,
        facilityId: facility.id,
        customerEmail: user!.email!,
        successUrl: 'https://storage-facility-creator.web.app/subscription/success?session_id={CHECKOUT_SESSION_ID}&facility_id=${facility.id}',
        cancelUrl: 'https://storage-facility-creator.web.app/subscription/cancel?facility_id=${facility.id}',
      );
      if (!mounted) return;
      if (result.subscriptionUpdated) {
        setState(() => _isCreatingCheckout = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.message ?? 'Facility already subscribed.'), backgroundColor: AppTheme.success),
        );
        _loadAccount();
        return;
      }
      final url = result.checkoutUrl!;
      setState(() {
        _checkoutUrl = url;
        _isCreatingCheckout = false;
      });
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Opening Stripe checkout — use a different card for this facility'),
              backgroundColor: AppTheme.success,
              duration: Duration(seconds: 4),
            ),
          );
        }
      } else {
        throw Exception('Browser blocked. Please allow popups.');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isCreatingCheckout = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${ErrorMessageHelper.getUserFriendlyMessage(e)}'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  /// Cancel subscription for one facility only.
  /// Per-facility model: calls cancelFacilitySubscription.
  /// Legacy: removes from account or cancels account sub.
  Future<void> _cancelSubscriptionForFacility(FacilityModel facility) async {
    if (_account == null || _isCancelling || _isRemovingFacility) return;

    // Per-facility: facility has its own subscription
    if (facility.stripePlatformSubscriptionId != null) {
      if (facility.platformSubscriptionCancelAtPeriodEnd) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.cancel_outlined, color: AppTheme.error),
              SizedBox(width: 8),
              Text('Cancel Subscription'),
            ],
          ),
          content: Text(
            'Cancel the subscription for "${facility.name}"? You will keep access until the end of the billing period, then this facility will be locked.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Keep')),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
              child: const Text('Yes, Cancel'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() => _isCancelling = true);
      try {
        await StripeService.cancelFacilitySubscription(facilityId: facility.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Subscription will cancel at period end.'), backgroundColor: AppTheme.success),
          );
          _loadAccount();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: ${ErrorMessageHelper.getUserFriendlyMessage(e)}')),
          );
        }
      } finally {
        if (mounted) setState(() => _isCancelling = false);
      }
      return;
    }

    // Legacy account-level
    if (_account!.subscriptionCancelAtPeriodEnd) return;
    final count = _account!.facilityIds.length;
    final isOnlyFacility = count <= 1;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.cancel_outlined, color: AppTheme.error),
            const SizedBox(width: 8),
            Text(isOnlyFacility ? 'Cancel Subscription' : 'Cancel Subscription for Facility'),
          ],
        ),
        content: Text(
          isOnlyFacility
              ? 'Cancel the subscription for "${facility.name}"? You will keep access until the end of your current billing period, then the facility will be locked. You can reactivate anytime from Manage Subscription.'
              : 'Cancel the subscription for "${facility.name}"? You will stop paying for this facility. It will be removed from your subscription and you will need to resubscribe to use it again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            child: Text(isOnlyFacility ? 'Yes, Cancel Subscription' : 'Yes, Cancel for This Facility'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    if (isOnlyFacility) {
      setState(() => _isCancelling = true);
      try {
        await StripeService.cancelSubscription(accountId: _account!.accountId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Subscription will cancel at end of billing period.'),
              backgroundColor: AppTheme.success,
            ),
          );
          _loadAccount();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: ${ErrorMessageHelper.getUserFriendlyMessage(e)}')),
          );
        }
      } finally {
        if (mounted) setState(() => _isCancelling = false);
      }
    } else {
      setState(() => _isRemovingFacility = true);
      try {
        await FacilityCreatorAccountService.removeFacilityFromAccount(
          accountId: _account!.accountId,
          facilityId: facility.id,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Facility removed from subscription.'),
              backgroundColor: AppTheme.success,
            ),
          );
          _loadAccount();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: ${ErrorMessageHelper.getUserFriendlyMessage(e)}')),
          );
        }
      } finally {
        if (mounted) setState(() => _isRemovingFacility = false);
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
      // Note: No ModernPageWrapper needed - already inside AppShell which provides sidebar
      child: SizedBox.expand(
        child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _account == null
              ? const Center(child: Text('No account found'))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Compact status summary (status, period, key alerts)
                      _buildStatusSummaryCard(),
                      const SizedBox(height: 16),

                      // Subscription Status Card (compact, neutral background for readability)
                      Card(
                        elevation: 2,
                        color: AppTheme.surface,
                        shape: RoundedRectangleBorder(
                          side: BorderSide(color: _getStatusColor(_account!.subscriptionStatus) ?? AppTheme.borderLight, width: 1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Top row: status chip + period + days remaining
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: _getStatusColor(_account!.subscriptionStatus) ?? AppTheme.backgroundSecondary,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      _account!.subscriptionStatus.displayName,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: _getStatusTextColor(_account!.subscriptionStatus),
                                      ),
                                    ),
                                  ),
                                  if (_account!.subscriptionCurrentPeriodEnd != null) ...[
                                    const SizedBox(width: 12),
                                    Text(
                                      'Until ${_formatDate(_account!.subscriptionCurrentPeriodEnd!)}',
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: AppTheme.textSecondary,
                                      ),
                                    ),
                                  ],
                                  if (_account!.daysUntilExpiration != null && _account!.daysUntilExpiration! > 0) ...[
                                    const SizedBox(width: 8),
                                    Text(
                                      '• ${_account!.daysUntilExpiration} days left',
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: AppTheme.textSecondary,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              // Inline alerts (trial, past due, cancel warning)
                              if (_account!.hasTrial && _account!.daysUntilTrialExpiration != null && !_account!.isTrialExpired)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                    'Trial: ${_account!.daysUntilTrialExpiration} days left',
                                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                                  ),
                                ),
                              if (_account!.isTrialExpired)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                    '⚠️ Trial expired. Subscribe to continue.',
                                    style: const TextStyle(fontSize: 12, color: AppTheme.error, fontWeight: FontWeight.w600),
                                  ),
                                )
                              else if (_account!.isTrialExpiringSoon)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                    '⚠️ Trial ends in ${_account!.daysUntilTrialExpiration} days.',
                                    style: const TextStyle(fontSize: 12, color: AppTheme.warning, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              if (_account!.isSubscriptionPastDue && _account!.canAccessPlatform)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                    '⚠️ Past due. ${_account!.daysRemainingInGracePeriod} days in grace period.',
                                    style: const TextStyle(fontSize: 12, color: AppTheme.warning, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              if (_account!.subscriptionCancelAtPeriodEnd)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                    '⚠️ Will cancel at period end',
                                    style: const TextStyle(fontSize: 12, color: AppTheme.warning, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              // Compact expandable technical details
                              if (_account!.stripeCustomerId != null || _account!.stripeSubscriptionId != null) ...[
                                const SizedBox(height: 8),
                                Theme(
                                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                                  child: ExpansionTile(
                                    tilePadding: EdgeInsets.zero,
                                    childrenPadding: const EdgeInsets.only(top: 4, bottom: 4),
                                    title: Text(
                                      'Account & billing details',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: AppTheme.textSecondary,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.only(left: 12, right: 8, bottom: 4),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            _buildInfoRow('Account ID', _account!.accountId),
                                            _buildInfoRow('Owner', '${_account!.ownerName} (${_account!.ownerEmail})'),
                                            _buildInfoRow('Facilities', '${_actualFacilityCount ?? _account!.facilityIds.length}'),
                                            if (_account!.stripeCustomerId != null)
                                              _buildInfoRow('Stripe Customer', _account!.stripeCustomerId!),
                                            if (_account!.stripeSubscriptionId != null)
                                              _buildInfoRow('Stripe Subscription', _account!.stripeSubscriptionId!),
                                            if (_account!.subscriptionCurrentPeriodStart != null)
                                              _buildInfoRow('Period Start', _formatDate(_account!.subscriptionCurrentPeriodStart!)),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
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
                                  'To use your facility, choose one option below. '
                                  'Start Free Trial = no payment, no card required. '
                                  'Subscribe = add a card for after your 30-day trial; you are not charged today.',
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
                              
                              // Free trial — activated by admin only
                              if (_account != null && !_account!.isSubscriptionActive) ...[
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: AppTheme.primaryBlue.withValues(alpha: 0.07),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: AppTheme.primaryBlue.withValues(alpha: 0.2),
                                    ),
                                  ),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Icon(Icons.info_outline,
                                          color: AppTheme.primaryBlue, size: 18),
                                      const SizedBox(width: 10),
                                      const Expanded(
                                        child: Text(
                                          'Free trials are activated by our team. '
                                          'Contact us to request a 30-day free trial for your account.',
                                          style: TextStyle(fontSize: 13),
                                        ),
                                      ),
                                    ],
                                  ),
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
                              
                              // Subscribe Button — only show when not already subscribed
                              if (_account != null && !_account!.isSubscriptionActive) ...[
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
                                      : 'Subscribe (30-day free trial, then \$75/mo + \$75 per extra facility)'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppTheme.success,
                                    foregroundColor: AppTheme.textOnDark,
                                    padding: const EdgeInsets.all(16),
                                  ),
                                ),
                                const SizedBox(height: 12),
                              ],

                              // Manage Subscription (Portal) — show when we have a Stripe customer (account or per-facility)
                              if (_account!.stripeCustomerId != null || _subscribedFacilities.any((f) => f.stripePlatformSubscriptionId != null)) ...[
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
                                const Text(
                                  'Manage Subscription opens Stripe Customer Portal:\n'
                                  '• Update payment method per facility • View invoices • Reactivate cancelled',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textTertiary,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 16),
                              ],
                              // Per-facility list: Subscribe or Cancel each facility (own card per facility)
                              if (_subscribedFacilities.isNotEmpty) ...[
                                const Text(
                                  'Per facility — own card each (\$75/mo)',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                const Text(
                                  'Each facility has its own subscription and payment method. Subscribe or cancel one at a time.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textTertiary,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                ..._subscribedFacilities.map((f) => Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: Card(
                                    margin: EdgeInsets.zero,
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(f.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                                                const SizedBox(height: 4),
                                                Text(
                                                  f.hasActivePlatformSubscription
                                                      ? '${f.platformSubscriptionStatus ?? "Active"} • \$75/mo'
                                                      : (f.platformSubscriptionStatus == 'past_due' ? 'Past due' : 'No subscription'),
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    color: f.hasActivePlatformSubscription ? AppTheme.success : AppTheme.textTertiary,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (f.hasActivePlatformSubscription) ...[
                                            OutlinedButton.icon(
                                              onPressed: (_isCancelling || _isRemovingFacility) ? null : _openCustomerPortal,
                                              icon: const Icon(Icons.settings, size: 16),
                                              label: const Text('Manage'),
                                              style: OutlinedButton.styleFrom(
                                                foregroundColor: AppTheme.primaryBlue,
                                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            OutlinedButton.icon(
                                              onPressed: (_isCancelling || _isRemovingFacility || f.platformSubscriptionCancelAtPeriodEnd)
                                                  ? null
                                                  : () => _cancelSubscriptionForFacility(f),
                                              icon: (_isCancelling || _isRemovingFacility)
                                                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                                                  : const Icon(Icons.cancel_outlined, size: 16),
                                              label: Text(f.platformSubscriptionCancelAtPeriodEnd ? 'Cancelling' : 'Cancel'),
                                              style: OutlinedButton.styleFrom(
                                                foregroundColor: AppTheme.error,
                                                side: const BorderSide(color: AppTheme.error),
                                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                              ),
                                            ),
                                          ] else
                                            ElevatedButton.icon(
                                              onPressed: _isCreatingCheckout ? null : () => _createFacilitySubscriptionCheckout(f),
                                              icon: _isCreatingCheckout
                                                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                                                  : const Icon(Icons.add_card, size: 18),
                                              label: const Text('Subscribe'),
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: AppTheme.success,
                                                foregroundColor: AppTheme.textOnDark,
                                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                )),
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

                      // Pricing & Facilities Info (show if has any subscription)
                      if (_account != null && (_account!.hasActiveSubscription || _subscribedFacilities.any((f) => f.hasActivePlatformSubscription))) ...[
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
                                const SizedBox(height: 8),
                                Text(
                                  _subscribedFacilities.any((f) => f.hasActivePlatformSubscription)
                                      ? 'Each facility: \$75/month with its own payment method. Subscribe or cancel per facility above.'
                                      : 'Your subscription covers ${_actualFacilityCount ?? _account!.facilityIds.length} facilities.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textTertiary,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                _buildInfoRow('Facilities', '${_actualFacilityCount ?? _account!.facilityIds.length}'),
                                if (_account!.hasActiveSubscription)
                                  _buildInfoRow(
                                    'Monthly Cost',
                                    '\$${_calculateMonthlyCost()}/month',
                                  )
                                else
                                  _buildInfoRow(
                                    'Per facility',
                                    '\$75/month (own card each)',
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

  Widget _buildStatusSummaryCard() {
    final activeFacilityId = ref.watch(activeFacilityIdProvider).whenOrNull(data: (d) => d);
    final facilitiesAsync = ref.watch(
      userFacilitiesProvider(ref.watch(authStateProvider).whenOrNull(data: (d) => d)?.uid ?? ''),
    );
    return facilitiesAsync.when(
      data: (facilities) {
        final count = _actualFacilityCount ?? _account?.facilityIds.length ?? facilities.length;
        final hasPerFacility = _subscribedFacilities.any((f) => f.hasActivePlatformSubscription);
        final monthly = hasPerFacility
            ? '\$${75 * _subscribedFacilities.where((f) => f.hasActivePlatformSubscription).length}/mo'
            : (_account?.hasActiveSubscription == true ? '\$${_calculateMonthlyCost()}/mo' : null);
        String subtitle;
        if (activeFacilityId == null) {
          subtitle = '$count ${count == 1 ? 'facility' : 'facilities'}${monthly != null ? ' • $monthly' : ''}';
        } else {
          final f = facilities.where((x) => x.id == activeFacilityId).firstOrNull;
          subtitle = f?.name ?? 'Selected facility';
        }
        return Card(
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
                      Text(
                        activeFacilityId == null ? 'All Facilities' : 'Viewing facility',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      Text(
                        subtitle,
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
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _buildFacilityContextBanner() {
    final activeFacilityId = ref.watch(activeFacilityIdProvider).whenOrNull(data: (d) => d);
    final facilitiesAsync = ref.watch(
      userFacilitiesProvider(ref.watch(authStateProvider).whenOrNull(data: (d) => d)?.uid ?? ''),
    );
    return facilitiesAsync.when(
      data: (facilities) {
        final count = _actualFacilityCount ?? _account?.facilityIds.length ?? facilities.length;
        if (activeFacilityId == null) {
          return Card(
            elevation: 2,
            color: AppTheme.primaryBlue.withOpacity(0.08),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.business_outlined, color: AppTheme.primaryBlue, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'All Facilities — Your subscription covers $count ${count == 1 ? 'facility' : 'facilities'}.',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppTheme.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        final facility = facilities.where((f) => f.id == activeFacilityId).firstOrNull;
        final name = facility?.name ?? 'Selected facility';
        return Card(
          elevation: 2,
          color: AppTheme.primaryBlue.withOpacity(0.08),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(Icons.business, color: AppTheme.primaryBlue, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '$name — This facility is included in your subscription.',
                    style: TextStyle(
                      fontSize: 14,
                      color: AppTheme.textSecondary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
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
      case SubscriptionStatus.pendingApproval:
        return Colors.amber.withValues(alpha: 0.1);
      default:
        return AppTheme.textTertiary.withOpacity(0.1);
    }
  }

  Color _getStatusTextColor(SubscriptionStatus status) {
    switch (status) {
      case SubscriptionStatus.active:
        return AppTheme.success;
      case SubscriptionStatus.trialing:
        return AppTheme.primaryBlue;
      case SubscriptionStatus.pastDue:
        return AppTheme.warning;
      case SubscriptionStatus.cancelled:
        return AppTheme.error;
      case SubscriptionStatus.pendingApproval:
        return Colors.amber.shade700;
      default:
        return AppTheme.textSecondary;
    }
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }

  double _calculateMonthlyCost() {
    if (_account == null) return 0;
    final facilityCount = _actualFacilityCount ?? _account!.facilityIds.length;
    // Always show at least $75 (base plan), even with 0 facilities
    if (facilityCount == 0) return 75.0;
    return 75.0 * facilityCount; // $75 per facility
  }
}

