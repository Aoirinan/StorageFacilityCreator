import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/facility_creator_account_model.dart';
import '../services/facility_creator_account_service.dart';
import '../services/superadmin_service.dart';
import 'error_reporter.dart';
import 'debug_logger.dart';

/// Result of subscription access check
class SubscriptionAccessResult {
  final bool canAccess;
  final String? redirectRoute;
  final String? message;
  final SubscriptionStatus? subscriptionStatus;

  const SubscriptionAccessResult({
    required this.canAccess,
    this.redirectRoute,
    this.message,
    this.subscriptionStatus,
  });
}

/// Service for checking subscription status and access permissions
/// Used by route guards to restrict access based on subscription status
class SubscriptionGuardService {
  /// Check if current user can access a route
  /// Returns access result with redirect route if access is denied
  static Future<SubscriptionAccessResult> checkAccess({
    String? currentRoute,
    bool allowSubscriptionRoutes = true,
    User? userOverride,
    Future<FacilityCreatorAccountModel?> Function(String uid)? accountProvider,
    bool Function()? superAdminResolver,
    FirebaseAuth? authOverride,
  }) async {
    try {
      final auth = authOverride ?? FirebaseAuth.instance;
      final user = userOverride ?? auth.currentUser;
      if (user == null) {
        // Not authenticated - let auth guard handle this
        return const SubscriptionAccessResult(canAccess: true);
      }

      // Superadmins bypass all subscription checks
      final isSuperAdmin = superAdminResolver?.call() ?? SuperAdminService.isSuperAdmin();
      if (isSuperAdmin) {
        if (kDebugMode) {
          print('✅ [SubscriptionGuard] Superadmin - bypassing subscription check');
        }
        // #region agent log
        DebugLogger.log(
          hypothesisId: 'H2',
          location: 'subscription_guard_service.dart:checkAccess',
          message: 'Bypass superadmin',
          data: {'route': currentRoute},
        );
        // #endregion
        return const SubscriptionAccessResult(canAccess: true);
      }

      // Get account for current user
      final accountFetcher =
          accountProvider ?? FacilityCreatorAccountService.getAccountByOwnerUid;
      final account = await accountFetcher(user.uid);
      if (account == null) {
        // No account yet - allow access (will be created on first facility creation)
        if (kDebugMode) {
          print('⚠️ [SubscriptionGuard] No account found - allowing access');
        }
        // #region agent log
        DebugLogger.log(
          hypothesisId: 'H2',
          location: 'subscription_guard_service.dart:checkAccess',
          message: 'No account found, allowing',
          data: {'route': currentRoute, 'user': user.uid},
        );
        // #endregion
        return const SubscriptionAccessResult(canAccess: true);
      }

      // Check subscription status
      final status = account.subscriptionStatus;

      // Always allow access to subscription management routes
      final subscriptionRoutes = [
        '/subscription',
        '/subscription/',
        '/subscription/success',
        '/subscription/cancel',
        '/subscription/manage',
      ];
      
      if (allowSubscriptionRoutes && 
          currentRoute != null && 
          subscriptionRoutes.any((route) => currentRoute.startsWith(route))) {
        return const SubscriptionAccessResult(canAccess: true);
      }

      // Check if user can access platform
      if (!account.canAccessPlatform) {
        if (kDebugMode) {
          print('❌ [SubscriptionGuard] Access denied - subscription status: ${status.name}');
        }
        ErrorReporter.reportInfo(
          'SubscriptionGuard deny: status=${status.name}, route=$currentRoute, user=${user.uid}',
        );
        String message;
        String redirectRoute = '/subscription';

        // #region agent log
        DebugLogger.log(
          hypothesisId: 'H2',
          location: 'subscription_guard_service.dart:checkAccess',
          message: 'Access denied',
          data: {
            'route': currentRoute,
            'status': status.name,
            'user': user.uid,
            'redirect': redirectRoute,
          },
        );
        // #endregion

        if (status == SubscriptionStatus.pastDue) {
          message = 'Your subscription is past due. Please update your payment method to continue using the platform.';
        } else if (status == SubscriptionStatus.cancelled) {
          if (account.subscriptionCurrentPeriodEnd != null &&
              DateTime.now().isBefore(account.subscriptionCurrentPeriodEnd!)) {
            message = 'Your subscription has been cancelled but you have access until ${account.subscriptionCurrentPeriodEnd!.toString().split(' ')[0]}.';
            // Allow access until period end
            return SubscriptionAccessResult(
              canAccess: true,
              message: message,
              subscriptionStatus: status,
            );
          } else {
            message = 'Your subscription has been cancelled. Please reactivate to continue using the platform.';
          }
        } else if (status == SubscriptionStatus.unpaid) {
          message = 'Please choose a subscription plan to continue using the platform.';
          redirectRoute = '/subscription?requireChoice=true';
        } else {
          message = 'Your subscription status needs attention. Please update your subscription to continue.';
        }

        return SubscriptionAccessResult(
          canAccess: false,
          redirectRoute: redirectRoute,
          message: message,
          subscriptionStatus: status,
        );
      }

      // Access granted
      if (kDebugMode) {
        print('✅ [SubscriptionGuard] Access granted - subscription status: ${status.name}');
      }

      // Return warning message if past due (but still allowing access during grace period)
      if (status == SubscriptionStatus.pastDue) {
        return SubscriptionAccessResult(
          canAccess: true,
          message: 'Your subscription is past due. Please update your payment method soon.',
          subscriptionStatus: status,
        );
      }

      return SubscriptionAccessResult(
        canAccess: true,
        subscriptionStatus: status,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [SubscriptionGuard] Error checking access: $e');
      }
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H2',
        location: 'subscription_guard_service.dart:checkAccess',
        message: 'Error during access check',
        data: {'route': currentRoute, 'error': e.toString()},
      );
      // #endregion
      ErrorReporter.reportError(e, StackTrace.current, context: 'SubscriptionGuard.checkAccess');
      // On error, deny access and route to subscription/help to avoid bypassing guards
      return const SubscriptionAccessResult(
        canAccess: false,
        redirectRoute: '/subscription',
        message: 'We could not verify your subscription status. Please check your connection or try again.',
      );
    }
  }

  /// Check if user needs to see subscription warning banner
  static Future<bool> shouldShowWarning() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null || SuperAdminService.isSuperAdmin()) {
        return false;
      }

      final account = await FacilityCreatorAccountService.getAccountByOwnerUid(user.uid);
      if (account == null) {
        return false;
      }

      // Show warning if past due or cancelled (but still have access)
      return account.subscriptionStatus == SubscriptionStatus.pastDue ||
             (account.subscriptionStatus == SubscriptionStatus.cancelled &&
              account.subscriptionCurrentPeriodEnd != null &&
              DateTime.now().isBefore(account.subscriptionCurrentPeriodEnd!));
    } catch (e) {
      return false;
    }
  }

  /// Get warning message for current subscription status
  static Future<String?> getWarningMessage() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null || SuperAdminService.isSuperAdmin()) {
        return null;
      }

      final account = await FacilityCreatorAccountService.getAccountByOwnerUid(user.uid);
      if (account == null) {
        return null;
      }

      if (account.subscriptionStatus == SubscriptionStatus.pastDue) {
        return 'Your subscription is past due. Please update your payment method.';
      }

      if (account.subscriptionStatus == SubscriptionStatus.cancelled &&
          account.subscriptionCurrentPeriodEnd != null &&
          DateTime.now().isBefore(account.subscriptionCurrentPeriodEnd!)) {
        final endDate = account.subscriptionCurrentPeriodEnd!.toString().split(' ')[0];
        return 'Your subscription has been cancelled. You have access until $endDate.';
      }

      return null;
    } catch (e) {
      return null;
    }
  }
}

