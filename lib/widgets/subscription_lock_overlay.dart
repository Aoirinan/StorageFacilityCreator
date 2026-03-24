import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/services/facility_creator_account_service.dart';
import 'package:sfcapp/services/facility_service.dart';
import 'package:sfcapp/services/stripe_service.dart';
import 'package:sfcapp/services/superadmin_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:url_launcher/url_launcher.dart';

/// Global overlay that disables all features when trial expired or no active subscription
/// Blocks all user interactions until subscription is active
class SubscriptionLockOverlay extends StatefulWidget {
  final Widget child;

  const SubscriptionLockOverlay({super.key, required this.child});

  @override
  State<SubscriptionLockOverlay> createState() => _SubscriptionLockOverlayState();
}

class _SubscriptionLockOverlayState extends State<SubscriptionLockOverlay> {
  FacilityCreatorAccountModel? _account;
  bool _isLoading = true;
  bool _isLocked = false;
  bool _isCreatingCheckout = false;

  @override
  void initState() {
    super.initState();
    if (kDebugMode) {
      print('🔒 [SubscriptionLock] Widget initialized');
    }
    _checkSubscription();
    _listenToAccount();
  }

  void _listenToAccount() {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      // Poll for account updates every 10 seconds
      Future.delayed(const Duration(seconds: 10), () {
        if (mounted) {
          _checkSubscription();
          _listenToAccount();
        }
      });
    }
  }

  Future<void> _checkSubscription() async {
    if (kDebugMode) {
      print('🔒 [SubscriptionLock] _checkSubscription() called');
    }
    try {
      final user = FirebaseAuth.instance.currentUser;
      
      if (user == null) {
        if (mounted) {
          setState(() {
            _isLocked = false;
            _isLoading = false;
          });
        }
        return;
      }

      // Superadmins (e.g. russell_forsyth_1992@outlook.com) bypass subscription lock for testing
      if (SuperAdminService.isSuperAdmin(user)) {
        if (kDebugMode) {
          print('🔒 [SubscriptionLock] SuperAdmin detected - unlocking');
        }
        if (mounted) {
          setState(() {
            _isLocked = false;
            _isLoading = false;
          });
        }
        return;
      }

      final account = await FacilityCreatorAccountService.getAccountByOwnerUid(user.uid);
      final facilities = await FacilityService.getUserFacilities(includeArchived: false, forceRefresh: false);
      final hasAccess = await FacilityCreatorAccountService.hasActiveSubscription(user.uid, facilities: facilities);

      if (mounted) {
        // hasAccess = account.canAccessPlatform (legacy) OR any facility has per-facility platform sub
        // Pending approval is handled by dedicated route guard/screen, not this overlay.
        bool isLocked = (account?.isPendingApproval ?? false) ? false : !hasAccess;
        if (kDebugMode) {
          print(isLocked
              ? '🔒 [SubscriptionLock] LOCKED: no active subscription'
              : '✅ [SubscriptionLock] UNLOCKED: has access');
        }
        setState(() {
          _account = account;
          _isLocked = isLocked;
          _isLoading = false;
        });

      } else if (kDebugMode) {
        print('🔒 [SubscriptionLock] Widget not mounted, skipping state update');
      }
    } catch (e, stackTrace) {
      print('❌ [SubscriptionLock] ERROR checking subscription: $e');
      print('❌ [SubscriptionLock] Stack trace: $stackTrace');
      if (mounted) {
        setState(() {
          _isLocked = false;
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
        successUrl: 'https://app.storagefacilitycreator.com/subscription/success?session_id={CHECKOUT_SESSION_ID}',
        cancelUrl: 'https://app.storagefacilitycreator.com/subscription/cancel',
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
        return;
      }

      final checkoutUrl = checkoutResult.checkoutUrl!;
      if (kDebugMode) {
        print('✅ Checkout URL received: $checkoutUrl');
      }

      // On web, open in new tab
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

  String _getLockMessage() {
    if (_account == null) return 'Please subscribe to continue.';
    
    if (_account!.hasTrial && _account!.isTrialExpired) {
      return 'Your trial has expired. Please subscribe to continue using the app.';
    }
    
    if (_account!.subscriptionStatus == SubscriptionStatus.pastDue) {
      return 'Your subscription payment is past due. Please renew your subscription to continue.';
    }
    
    if (_account!.subscriptionStatus == SubscriptionStatus.cancelled) {
      return 'Your subscription has been cancelled. Please reactivate to continue.';
    }
    
    return 'Please subscribe to continue using the app.';
  }

  @override
  Widget build(BuildContext context) {
    // Always allow access to subscription page
    final currentRoute = GoRouter.of(context).routeInformationProvider.value.location ?? '';
    final isSubscriptionRoute = currentRoute.startsWith('/subscription');
    final isPendingApprovalRoute = currentRoute.startsWith(AppRoute.pendingApproval);
    
    // While loading, show content but check subscription immediately
    if (_isLoading) {
      // Re-check immediately if we haven't loaded yet
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _checkSubscription();
        }
      });
      return widget.child;
    }
    
    // Always allow subscription page
    if (isSubscriptionRoute || isPendingApprovalRoute) {
      return widget.child;
    }

    if (!_isLocked) {
      return widget.child; // No lock needed
    }

    // CRITICAL: Show blocking overlay - MUST block ALL interactions
    // Use Material to ensure proper z-index and blocking
    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          // Blurred/disabled content - COMPLETELY block all interactions
          Positioned.fill(
            child: AbsorbPointer(
              absorbing: true,
              child: Opacity(
                opacity: 0.2,
                child: widget.child,
              ),
            ),
          ),
          // Full-screen blocking overlay with clickable modal
          Positioned.fill(
            child: Container(
              color: Colors.black.withOpacity(0.7),
              child: Center(
                child: Card(
                  margin: const EdgeInsets.all(24),
                  elevation: 8,
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.lock_outline,
                          size: 64,
                          color: AppTheme.error,
                        ),
                        const SizedBox(height: 24),
                        Text(
                          'Subscription Required',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _getLockMessage(),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 16,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 32),
                        FilledButton.icon(
                          onPressed: _isCreatingCheckout ? null : _createSubscriptionCheckout,
                          icon: _isCreatingCheckout
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : const Icon(Icons.payment, size: 20),
                          label: Text(_isCreatingCheckout ? 'Opening Checkout...' : 'Subscribe Now'),
                          style: FilledButton.styleFrom(
                            backgroundColor: AppTheme.error,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            minimumSize: const Size(200, 48),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextButton(
                          onPressed: () {
                            context.go(AppRoute.subscription);
                          },
                          child: const Text('Manage Subscription'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
