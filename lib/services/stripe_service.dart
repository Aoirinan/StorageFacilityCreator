import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// Service for interacting with Stripe via Firebase Cloud Functions
/// All Stripe operations are handled server-side for security
class StripeService {
  static final FirebaseFunctions _functions = FirebaseFunctions.instance;

  /// Create a Stripe Checkout session for subscription
  /// Returns the checkout session URL
  static Future<String> createSubscriptionCheckout({
    required String accountId,
    required String customerEmail,
    String? successUrl,
    String? cancelUrl,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Creating Stripe checkout session for account: $accountId');
      }

      final callable = _functions.httpsCallable('createSubscriptionCheckout');
      final result = await callable.call(<String, dynamic>{
        'accountId': accountId,
        'customerEmail': customerEmail,
        'successUrl': successUrl ?? 'https://storage-facility-creator.web.app/subscription/success?session_id={CHECKOUT_SESSION_ID}',
        'cancelUrl': cancelUrl ?? 'https://storage-facility-creator.web.app/subscription/cancel',
      }).timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          throw Exception('Request timed out. Please try again.');
        },
      );

      final checkoutUrl = result.data['checkoutUrl'] as String?;
      if (checkoutUrl == null) {
        throw Exception('Failed to create checkout session');
      }

      if (kDebugMode) {
        print('✅ Checkout session created: $checkoutUrl');
      }

      return checkoutUrl;
    } catch (e) {
      // If price IDs are inactive or missing, surface a more helpful hint.
      final msg = e.toString();
      if (msg.contains('not available to be purchased')) {
        throw Exception(
          'Subscription price is inactive. Please verify STRIPE_BASE_PRICE_ID / STRIPE_ADDON_PRICE_ID are active in Stripe.',
        );
      }
      if (kDebugMode) {
        print('❌ Error creating checkout session: $e');
      }
      rethrow;
    }
  }

  /// Create a Stripe Customer Portal session
  /// Allows customers to manage their subscription, update payment method, etc.
  static Future<String> createCustomerPortalSession({
    required String accountId,
    String? returnUrl,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Creating customer portal session for account: $accountId');
      }

      final callable = _functions.httpsCallable('createCustomerPortalSession');
      final result = await callable.call(<String, dynamic>{
        'accountId': accountId,
        'returnUrl': returnUrl ?? 'https://storage-facility-creator.web.app/subscription/manage',
      });

      final portalUrl = result.data['portalUrl'] as String?;
      if (portalUrl == null) {
        throw Exception('Failed to create portal session');
      }

      if (kDebugMode) {
        print('✅ Portal session created: $portalUrl');
      }

      return portalUrl;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating portal session: $e');
      }
      rethrow;
    }
  }

  /// Get subscription status for an account
  static Future<Map<String, dynamic>> getSubscriptionStatus(String accountId) async {
    try {
      if (kDebugMode) {
        print('🔄 Getting subscription status for account: $accountId');
      }

      final callable = _functions.httpsCallable('getSubscriptionStatus');
      final result = await callable.call(<String, dynamic>{
        'accountId': accountId,
      });

      return Map<String, dynamic>.from(result.data);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting subscription status: $e');
      }
      rethrow;
    }
  }

  /// Create a payment checkout session for public payment links
  /// No authentication required - uses token-based validation
  static Future<String> createPublicPaymentCheckout({
    required String token,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Creating public payment checkout for token: $token');
      }

      final callable = _functions.httpsCallable('createPublicPaymentCheckout');
      final result = await callable.call(<String, dynamic>{
        'token': token,
      }).timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          throw Exception('Request timed out. Please try again.');
        },
      );

      final checkoutUrl = result.data['checkoutUrl'] as String?;
      if (checkoutUrl == null) {
        throw Exception('Failed to create checkout session');
      }

      if (kDebugMode) {
        print('✅ Public payment checkout created: $checkoutUrl');
      }

      return checkoutUrl;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating public payment checkout: $e');
      }
      rethrow;
    }
  }

  /// Create a payment checkout session for tenant portal payment
  /// Uses email + accessCode for authentication (no Firebase Auth required)
  static Future<String> createTenantPortalPaymentCheckout({
    required String email,
    required String accessCode,
    required double amount,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Creating tenant portal payment checkout: \$$amount');
      }

      final callable = _functions.httpsCallable('createTenantPortalPaymentCheckout');
      final result = await callable.call(<String, dynamic>{
        'email': email.trim().toLowerCase(),
        'accessCode': accessCode.trim(),
        'amount': amount,
      }).timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          throw Exception('Request timed out. Please try again.');
        },
      );

      final checkoutUrl = result.data['checkoutUrl'] as String?;
      if (checkoutUrl == null) {
        throw Exception('Failed to create checkout session');
      }

      if (kDebugMode) {
        print('✅ Tenant portal payment checkout created: $checkoutUrl');
      }

      return checkoutUrl;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating tenant portal payment checkout: $e');
      }
      rethrow;
    }
  }

  /// Create a payment checkout session for tenant rent payment
  /// Routes payment to facility owner's Stripe Connect account (0% platform fee)
  static Future<String> createTenantPaymentCheckout({
    required String facilityId,
    required String tenantId,
    required double amount,
    String? description,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Creating tenant payment checkout: $facilityId, $tenantId, \$$amount');
      }

      final callable = _functions.httpsCallable('createTenantPaymentCheckout');
      final result = await callable.call(<String, dynamic>{
        'facilityId': facilityId,
        'tenantId': tenantId,
        'amount': amount,
        'description': description,
      });

      final checkoutUrl = result.data['checkoutUrl'] as String?;
      if (checkoutUrl == null) {
        throw Exception('Failed to create checkout session');
      }

      if (kDebugMode) {
        print('✅ Tenant payment checkout created: $checkoutUrl');
      }

      return checkoutUrl;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating tenant payment checkout: $e');
      }
      rethrow;
    }
  }

  /// Create a Stripe Connect account for a facility
  static Future<String> createStripeConnectAccount({
    required String facilityId,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Creating Stripe Connect account for facility: $facilityId');
      }

      final callable = _functions.httpsCallable('createStripeConnectAccount');
      final result = await callable.call(<String, dynamic>{
        'facilityId': facilityId,
      });

      final accountId = result.data['accountId'] as String?;
      if (accountId == null) {
        throw Exception('Failed to create Stripe Connect account');
      }

      if (kDebugMode) {
        print('✅ Stripe Connect account created: $accountId');
      }

      return accountId;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating Stripe Connect account: $e');
      }
      rethrow;
    }
  }

  /// Create an account link for Stripe Connect onboarding
  /// Returns a URL that the facility owner visits to complete onboarding
  static Future<String> createStripeConnectAccountLink({
    required String facilityId,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Creating Stripe Connect account link for facility: $facilityId');
      }

      final callable = _functions.httpsCallable('createStripeConnectAccountLink');
      final result = await callable.call(<String, dynamic>{
        'facilityId': facilityId,
      });

      final url = result.data['url'] as String?;
      if (url == null) {
        throw Exception('Failed to create account link');
      }

      if (kDebugMode) {
        print('✅ Stripe Connect account link created: $url');
      }

      return url;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating Stripe Connect account link: $e');
      }
      rethrow;
    }
  }

  /// Start a 30-day trial for an account
  static Future<Map<String, dynamic>> startTrial({
    required String accountId,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Starting 30-day trial for account: $accountId');
      }

      final callable = _functions.httpsCallable('startTrial');
      final result = await callable.call(<String, dynamic>{
        'accountId': accountId,
      });

      if (kDebugMode) {
        print('✅ Trial started successfully');
      }

      return Map<String, dynamic>.from(result.data);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error starting trial: $e');
      }
      rethrow;
    }
  }

  /// Get Stripe Connect account status for a facility
  static Future<Map<String, dynamic>> getStripeConnectAccountStatus({
    required String facilityId,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Getting Stripe Connect account status for facility: $facilityId');
      }

      final callable = _functions.httpsCallable('getStripeConnectAccountStatus');
      final result = await callable.call(<String, dynamic>{
        'facilityId': facilityId,
      });

      return Map<String, dynamic>.from(result.data);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting Stripe Connect account status: $e');
      }
      rethrow;
    }
  }
}

