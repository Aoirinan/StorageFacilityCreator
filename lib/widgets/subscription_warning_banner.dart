import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/services/facility_creator_account_service.dart';
import 'package:sfcapp/services/stripe_service.dart';
import 'package:sfcapp/services/subscription_guard_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// Banner widget that displays subscription warnings (past due, cancelled, trial expired, etc.)
/// Should be displayed at the top of protected screens
/// Shows "Subscribe Now" button that works from any page
class SubscriptionWarningBanner extends StatefulWidget {
  const SubscriptionWarningBanner({super.key});

  @override
  State<SubscriptionWarningBanner> createState() => _SubscriptionWarningBannerState();
}

class _SubscriptionWarningBannerState extends State<SubscriptionWarningBanner> {
  bool _showWarning = false;
  String? _warningMessage;
  bool _isLoading = true;
  FacilityCreatorAccountModel? _account;
  bool _isCreatingCheckout = false;
  bool _isCritical = false; // Trial expired or past due - not dismissible

  @override
  void initState() {
    super.initState();
    _checkWarning();
    // Listen for account updates
    _listenToAccount();
  }

  void _listenToAccount() {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      // Poll for account updates every 30 seconds
      Future.delayed(const Duration(seconds: 30), () {
        if (mounted) {
          _checkWarning();
          _listenToAccount();
        }
      });
    }
  }

  Future<void> _checkWarning() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final account = await SubscriptionGuardService.getCurrentAccount();
      
      // Check if we should show warning based on account status
      bool shouldShow = false;
      String? message;
      bool isCritical = false;

      if (account != null) {
        // Trial expired - always show
        if (account.hasTrial && account.isTrialExpired) {
          shouldShow = true;
          message = 'Your trial has expired. Please subscribe to continue using the app.';
          isCritical = true;
        }
        // Past due - show if in grace period or expired
        else if (account.subscriptionStatus == SubscriptionStatus.pastDue) {
          shouldShow = true;
          message = 'Your subscription payment is past due. Please renew your subscription to continue.';
          isCritical = true;
        }
        // Cancelled but still in grace period
        else if (account.subscriptionStatus == SubscriptionStatus.cancelled &&
                 account.subscriptionCurrentPeriodEnd != null &&
                 DateTime.now().isBefore(account.subscriptionCurrentPeriodEnd!)) {
          final endDate = account.subscriptionCurrentPeriodEnd!.toString().split(' ')[0];
          shouldShow = true;
          message = 'Your subscription has been cancelled. You have access until $endDate.';
          isCritical = false;
        }
        // No active subscription (unpaid)
        else if (!account.isSubscriptionActive && !account.hasTrial) {
          shouldShow = true;
          message = 'Please subscribe to continue using the app.';
          isCritical = true;
        }
      }

      if (kDebugMode) {
        print('🔔 [SubscriptionBanner] shouldShow=$shouldShow, message=$message, account=${account?.accountId}');
      }

      if (mounted) {
        setState(() {
          _showWarning = shouldShow;
          _warningMessage = message;
          _account = account;
          _isCritical = isCritical;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [SubscriptionBanner] Error checking warning: $e');
      }
      if (mounted) {
        setState(() {
          _showWarning = false;
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _createSubscriptionCheckout() async {
    if (_account == null) {
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
      final user = FirebaseAuth.instance.currentUser;
      if (user?.email == null) {
        throw Exception('User email not available');
      }

      final checkoutResult = await StripeService.createSubscriptionCheckout(
        accountId: _account!.accountId,
        customerEmail: user!.email!,
        successUrl: 'https://storage-facility-creator.web.app/subscription/success?session_id={CHECKOUT_SESSION_ID}',
        cancelUrl: 'https://storage-facility-creator.web.app/subscription/cancel',
      );

      if (!mounted) return;
      if (checkoutResult.subscriptionUpdated) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(checkoutResult.message ?? 'Subscription updated to include your new facility.'),
            backgroundColor: AppTheme.success,
            duration: const Duration(seconds: 5),
          ),
        );
        _checkWarning();
        return;
      }

      final checkoutUrl = checkoutResult.checkoutUrl!;
      if (kDebugMode) {
        print('✅ Checkout URL received: $checkoutUrl');
      }

      // On web, open in new tab
      if (kIsWeb) {
        final uri = Uri.parse(checkoutUrl);
        final canLaunch = await canLaunchUrl(uri);
        if (canLaunch) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
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
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error creating checkout: ${e.toString()}'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCreatingCheckout = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || !_showWarning || _warningMessage == null) {
      return const SizedBox.shrink();
    }

    final isCritical = _isCritical; // Trial expired or past due

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isCritical ? AppTheme.error.withOpacity(0.1) : AppTheme.warning.withOpacity(0.1),
        border: Border(
          bottom: BorderSide(
            color: isCritical ? AppTheme.error.withOpacity(0.3) : AppTheme.warning.withOpacity(0.3),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isCritical ? Icons.error_outline : Icons.warning_amber_rounded,
            color: isCritical ? AppTheme.error : AppTheme.warning,
            size: 24,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _warningMessage!,
              style: TextStyle(
                color: isCritical ? AppTheme.error : AppTheme.warning,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          // Subscribe Now button (works from any page)
          FilledButton.icon(
            onPressed: _isCreatingCheckout ? null : _createSubscriptionCheckout,
            icon: _isCreatingCheckout
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.payment, size: 18),
            label: Text(_isCreatingCheckout ? 'Opening...' : 'Subscribe Now'),
            style: FilledButton.styleFrom(
              backgroundColor: isCritical ? AppTheme.error : AppTheme.warning,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
          ),
          const SizedBox(width: 8),
          // Manage Subscription button (secondary action)
          TextButton(
            onPressed: () {
              context.push(AppRoute.subscription);
            },
            child: const Text(
              'Manage',
              style: TextStyle(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          // Dismiss button (only for non-critical warnings)
          if (!isCritical)
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              color: AppTheme.warning,
              onPressed: () {
                setState(() {
                  _showWarning = false;
                });
              },
              tooltip: 'Dismiss',
            ),
        ],
      ),
    );
  }
}

