import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/services/subscription_guard_service.dart';
import 'package:sfcapp/services/superadmin_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:url_launcher/url_launcher.dart';

/// What [SubscriptionGuardService.shellLock] answers.
typedef ShellLockAnswer = ({
  FacilityCreatorAccountModel? account,
  bool? locked,
  String? message,
});

/// Global overlay that disables all features when trial expired or no active subscription
/// Blocks all user interactions until subscription is active
class SubscriptionLockOverlay extends StatefulWidget {
  final Widget child;

  /// The signed-in user, the lock's answer for a uid and what "Contact
  /// support" does: Firebase Auth, [SubscriptionGuardService.shellLock] and
  /// an email to [supportEmail], unless a test passes its own.
  final User? Function()? currentUser;
  final Future<ShellLockAnswer> Function(String uid)? shellLock;
  final Future<void> Function()? contactSupport;

  const SubscriptionLockOverlay({
    super.key,
    required this.child,
    this.currentUser,
    this.shellLock,
    this.contactSupport,
  });

  static const String supportEmail = 'support@storagefacilitycreator.com';

  /// Whether the lock is a suspension. Paying does not lift one, so the
  /// overlay offers support instead of Subscribe and Manage Subscription.
  /// (An exempt account is never locked, suspended or not.)
  @visibleForTesting
  static bool isSuspension(FacilityCreatorAccountModel? account) => account?.suspended == true;

  /// What the lock says: [accessMessage], the reason the access rule gave
  /// ([SubscriptionGuardService.shellLock]), whenever there is one. It used to
  /// be read only with no account, so a suspended account (status cancelled)
  /// was told to reactivate its subscription, which does not lift a
  /// suspension, instead of that it is suspended. The account's own status is
  /// the fallback.
  @visibleForTesting
  static String lockMessage({
    required FacilityCreatorAccountModel? account,
    required String? accessMessage,
  }) {
    if (accessMessage != null) return accessMessage;
    if (account == null) return 'Please subscribe to continue.';

    if (account.hasTrial && account.isTrialExpired) {
      return 'Your trial has expired. Please subscribe to continue using the app.';
    }

    if (account.subscriptionStatus == SubscriptionStatus.pastDue) {
      return 'Your subscription payment is past due. Please renew your subscription to continue.';
    }

    if (account.subscriptionStatus == SubscriptionStatus.cancelled) {
      return 'Your subscription has been cancelled. Please reactivate to continue.';
    }

    return 'Please subscribe to continue using the app.';
  }

  @override
  State<SubscriptionLockOverlay> createState() => _SubscriptionLockOverlayState();
}

class _SubscriptionLockOverlayState extends State<SubscriptionLockOverlay> {
  FacilityCreatorAccountModel? _account;
  // Why the access rule locked (a suspension, a lapsed trial, a team
  // member's owner whose billing lapsed); see SubscriptionLockOverlay.lockMessage.
  String? _lockMessage;
  bool _isLoading = true;
  bool _isLocked = false;
  Timer? _poll;

  User? _signedInUser() => (widget.currentUser ?? () => FirebaseAuth.instance.currentUser)();

  @override
  void initState() {
    super.initState();
    if (kDebugMode) {
      print('🔒 [SubscriptionLock] Widget initialized');
    }
    _checkSubscription();
    _listenToAccount();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _listenToAccount() {
    if (_signedInUser() != null) {
      // Poll for account updates every 10 seconds. A periodic timer that
      // dispose cancels, rather than a chain of delayed futures left pending.
      _poll = Timer.periodic(const Duration(seconds: 10), (_) {
        if (mounted) _checkSubscription();
      });
    }
  }

  Future<void> _contactSupport() async {
    final contact = widget.contactSupport;
    if (contact != null) return contact();
    await launchUrl(Uri(
      scheme: 'mailto',
      path: SubscriptionLockOverlay.supportEmail,
      query: 'subject=${Uri.encodeComponent('Suspended account')}',
    ));
  }

  Future<void> _checkSubscription() async {
    if (kDebugMode) {
      print('🔒 [SubscriptionLock] _checkSubscription() called');
    }
    try {
      final user = _signedInUser();

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

      // The route guard's rule: an invited staff member (no account of their
      // own) and a cancelled account still inside its paid period are let
      // in, and were locked out here. Pending approval is handled by its own
      // route guard/screen, not this overlay.
      final lock = await (widget.shellLock ?? SubscriptionGuardService.shellLock)(user.uid);

      if (mounted) {
        final locked = lock.locked;
        if (kDebugMode) {
          print(locked == null
              ? '🔒 [SubscriptionLock] check failed, keeping current state'
              : locked
                  ? '🔒 [SubscriptionLock] LOCKED: no active subscription'
                  : '✅ [SubscriptionLock] UNLOCKED: has access');
        }
        setState(() {
          // Null: a read failed (e.g. a slow connection). Keep what is shown
          // rather than locking a paying owner out; the guard fails closed.
          if (locked != null) {
            _account = lock.account;
            _lockMessage = lock.message;
            _isLocked = locked;
          }
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


  String _getLockMessage() =>
      SubscriptionLockOverlay.lockMessage(account: _account, accessMessage: _lockMessage);

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

    final suspended = SubscriptionLockOverlay.isSuspension(_account);

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
                          suspended ? 'Account Suspended' : 'Subscription Required',
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
                        // Paying does not lift a suspension, so a suspended
                        // account is pointed at support, not at billing.
                        if (suspended) ...[
                          FilledButton.icon(
                            onPressed: _contactSupport,
                            icon: const Icon(Icons.mail_outline, size: 20),
                            label: const Text('Contact support'),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                              minimumSize: const Size(200, 48),
                            ),
                          ),
                          const SizedBox(height: 16),
                          const SelectableText(SubscriptionLockOverlay.supportEmail),
                        ] else ...[
                          FilledButton.icon(
                            onPressed: () => context.go(AppRoute.subscription),
                            icon: const Icon(Icons.payment, size: 20),
                            label: const Text('Subscribe your facility (\$75/mo)'),
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
