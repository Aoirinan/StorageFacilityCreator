import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// Result of createSubscriptionCheckout: either a checkout URL or subscription was updated (no payment now).
class SubscriptionCheckoutResult {
  final String? checkoutUrl;
  final bool subscriptionUpdated;
  final String? message;

  const SubscriptionCheckoutResult({
    this.checkoutUrl,
    this.subscriptionUpdated = false,
    this.message,
  });
}

/// Service for interacting with Stripe via Firebase Cloud Functions
/// All Stripe operations are handled server-side for security
class StripeService {
  static final FirebaseFunctions _functions = FirebaseFunctions.instance;

  /// Create a Stripe Checkout session for subscription, or update existing subscription if already active/trialing.
  /// Returns [SubscriptionCheckoutResult]: use [checkoutUrl] to open checkout, or [subscriptionUpdated]/[message] when no checkout needed.
  static Future<SubscriptionCheckoutResult> createSubscriptionCheckout({
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
        'successUrl': successUrl ?? 'https://app.storagefacilitycreator.com/subscription/success?session_id={CHECKOUT_SESSION_ID}',
        'cancelUrl': cancelUrl ?? 'https://app.storagefacilitycreator.com/subscription/cancel',
      }).timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          throw Exception('Request timed out. Please try again.');
        },
      );

      final data = result.data as Map<String, dynamic>? ?? {};
      final subscriptionUpdated = data['subscriptionUpdated'] as bool? ?? false;
      final message = data['message'] as String?;
      final checkoutUrl = data['checkoutUrl'] as String?;

      if (subscriptionUpdated) {
        if (kDebugMode) {
          print('✅ Subscription updated (no checkout): $message');
        }
        return SubscriptionCheckoutResult(subscriptionUpdated: true, message: message);
      }

      if (checkoutUrl == null || checkoutUrl.isEmpty) {
        throw Exception('Failed to create checkout session');
      }

      if (kDebugMode) {
        print('✅ Checkout session created: $checkoutUrl');
      }

      return SubscriptionCheckoutResult(checkoutUrl: checkoutUrl);
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

  /// Create Stripe Checkout for ONE facility's platform subscription.
  /// Each facility gets its own $75/mo subscription and payment method (different card per facility).
  static Future<SubscriptionCheckoutResult> createFacilitySubscriptionCheckout({
    required String accountId,
    required String facilityId,
    required String customerEmail,
    String? successUrl,
    String? cancelUrl,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Creating facility subscription checkout: $facilityId');
      }
      final callable = _functions.httpsCallable('createFacilitySubscriptionCheckout');
      final result = await callable.call(<String, dynamic>{
        'accountId': accountId,
        'facilityId': facilityId,
        'customerEmail': customerEmail,
        'successUrl': successUrl,
        'cancelUrl': cancelUrl,
      }).timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw Exception('Request timed out. Please try again.'),
      );
      final data = result.data as Map<String, dynamic>? ?? {};
      final subscriptionUpdated = data['subscriptionUpdated'] as bool? ?? false;
      final message = data['message'] as String?;
      final checkoutUrl = data['checkoutUrl'] as String?;
      if (subscriptionUpdated) {
        return SubscriptionCheckoutResult(subscriptionUpdated: true, message: message);
      }
      if (checkoutUrl == null || checkoutUrl.isEmpty) {
        throw Exception('Failed to create checkout session');
      }
      return SubscriptionCheckoutResult(checkoutUrl: checkoutUrl);
    } catch (e) {
      if (kDebugMode) print('❌ Facility checkout error: $e');
      rethrow;
    }
  }

  /// Cancel one facility's platform subscription at period end.
  static Future<void> cancelFacilitySubscription({required String facilityId}) async {
    try {
      if (kDebugMode) print('🔄 Cancelling facility subscription: $facilityId');
      final callable = _functions.httpsCallable('cancelFacilitySubscription');
      await callable.call(<String, dynamic>{'facilityId': facilityId});
      if (kDebugMode) print('✅ Facility subscription set to cancel at period end');
    } catch (e) {
      if (kDebugMode) print('❌ Error cancelling facility subscription: $e');
      rethrow;
    }
  }

  /// Cancel subscription at end of billing period (in-app, no Stripe portal)
  static Future<void> cancelSubscription({required String accountId}) async {
    try {
      if (kDebugMode) {
        print('🔄 Cancelling subscription for account: $accountId');
      }
      final callable = _functions.httpsCallable('cancelSubscription');
      await callable.call(<String, dynamic>{'accountId': accountId});
      if (kDebugMode) {
        print('✅ Subscription set to cancel at period end');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error cancelling subscription: $e');
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
        'returnUrl': returnUrl ?? 'https://app.storagefacilitycreator.com/subscription/manage',
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
      }).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          throw Exception('Request timed out. Please try again.');
        },
      );

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
      }).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          throw Exception('Request timed out. Please try again.');
        },
      );

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
      }).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          throw Exception('Request timed out. Please try again.');
        },
      );

      return Map<String, dynamic>.from(result.data);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting Stripe Connect account status: $e');
      }
      rethrow;
    }
  }

  /// Create a Stripe Connect login link for facility owners to access their Stripe Dashboard
  /// Feature-flagged: Requires connectEnabledGlobal OR facilityId in allowlist
  static Future<String> createStripeConnectLoginLink({
    required String facilityId,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Creating Stripe Connect login link for facility: $facilityId');
      }

      final callable = _functions.httpsCallable('createStripeConnectLoginLink');
      final result = await callable.call(<String, dynamic>{
        'facilityId': facilityId,
      });

      final url = result.data['url'] as String?;
      if (url == null) {
        throw Exception('Failed to create login link');
      }

      if (kDebugMode) {
        print('✅ Stripe Connect login link created: $url');
      }

      return url;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating Stripe Connect login link: $e');
      }
      rethrow;
    }
  }

  /// Create a SetupIntent on a connected account for tenant payment method capture
  /// Feature-flagged: Requires tenantAutopayEnabledGlobal OR facilityId in allowlist
  /// Returns clientSecret for use with Stripe Elements
  static Future<Map<String, dynamic>> createTenantSetupIntent({
    required String facilityId,
    required String tenantId,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Creating tenant SetupIntent on connected account: $facilityId, $tenantId');
      }

      final callable = _functions.httpsCallable('createTenantSetupIntent');
      final result = await callable.call(<String, dynamic>{
        'facilityId': facilityId,
        'tenantId': tenantId,
      });

      final clientSecret = result.data['clientSecret'] as String?;
      final setupIntentId = result.data['setupIntentId'] as String?;

      if (clientSecret == null) {
        throw Exception('Failed to create tenant setup intent');
      }

      if (kDebugMode) {
        print('✅ Tenant SetupIntent created: $setupIntentId');
      }

      final publishableKey = result.data['publishableKey'] as String?;
      final connectedAccountId = result.data['connectedAccountId'] as String?;
      return {
        'clientSecret': clientSecret,
        'setupIntentId': setupIntentId,
        'publishableKey': publishableKey,
        'connectedAccountId': connectedAccountId,
      };
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating tenant SetupIntent: $e');
      }
      rethrow;
    }
  }

  /// Attach a payment method to a customer on a connected account after SetupIntent confirmation
  /// Feature-flagged: Requires tenantAutopayEnabledGlobal OR facilityId in allowlist
  static Future<Map<String, dynamic>> attachTenantPaymentMethod({
    required String facilityId,
    required String tenantId,
    required String paymentMethodId,
    String? setupIntentId,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Attaching tenant payment method on connected account: $paymentMethodId');
      }

      final callable = _functions.httpsCallable('attachTenantPaymentMethod');
      final result = await callable.call(<String, dynamic>{
        'facilityId': facilityId,
        'tenantId': tenantId,
        'paymentMethodId': paymentMethodId,
        'setupIntentId': setupIntentId,
      });

      final success = result.data['success'] as bool? ?? false;
      final paymentMethodDocId = result.data['paymentMethodId'] as String?;
      final displayInfo = result.data['displayInfo'] as Map<String, dynamic>?;

      if (!success || paymentMethodDocId == null) {
        throw Exception('Failed to attach tenant payment method');
      }

      if (kDebugMode) {
        print('✅ Tenant payment method attached: $paymentMethodDocId');
      }

      return {
        'success': true,
        'paymentMethodId': paymentMethodDocId,
        'displayInfo': displayInfo,
      };
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error attaching tenant payment method: $e');
      }
      rethrow;
    }
  }

  /// When Stripe Link/3DS redirects for verification, the iframe never gets the result.
  /// Call this after redirect with setupIntentId from the URL to attach the payment method.
  static Future<Map<String, dynamic>> attachTenantPaymentMethodFromRedirect({
    required String facilityId,
    required String tenantId,
    required String setupIntentId,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Attaching tenant payment method from redirect: $setupIntentId');
      }
      final callable = _functions.httpsCallable('attachTenantPaymentMethodFromRedirect');
      final result = await callable.call(<String, dynamic>{
        'facilityId': facilityId,
        'tenantId': tenantId,
        'setupIntentId': setupIntentId,
      });
      final data = result.data as Map<String, dynamic>? ?? {};
      if (kDebugMode) {
        print('✅ Payment method attached from redirect');
      }
      return data;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error attaching from redirect: $e');
      }
      rethrow;
    }
  }

  /// Portal (no Firebase Auth): create SetupIntent for adding card. Returns clientSecret, publishableKey, connectedAccountId.
  static Future<Map<String, dynamic>> createTenantSetupIntentFromPortal({
    required String email,
    required String accessCode,
  }) async {
    final result = await _functions.httpsCallable('createTenantSetupIntentFromPortal').call({
      'email': email.trim().toLowerCase(),
      'accessCode': accessCode.trim(),
    });
    final data = result.data as Map<String, dynamic>;
    return {
      'clientSecret': data['clientSecret'],
      'setupIntentId': data['setupIntentId'],
      'publishableKey': data['publishableKey'],
      'connectedAccountId': data['connectedAccountId'],
    };
  }

  /// Portal: attach payment method after SetupIntent confirm (optional; webhook also updates tenant.stripe).
  static Future<void> attachTenantPaymentMethodFromPortal({
    required String email,
    required String accessCode,
    required String paymentMethodId,
    String? setupIntentId,
  }) async {
    await _functions.httpsCallable('attachTenantPaymentMethodFromPortal').call({
      'email': email.trim().toLowerCase(),
      'accessCode': accessCode.trim(),
      'paymentMethodId': paymentMethodId,
      'setupIntentId': setupIntentId,
    });
  }

  /// Create a one-time PaymentIntent on connected account for paying with a NEW card.
  /// Returns clientSecret, publishableKey, connectedAccountId for embedded Payment Element.
  static Future<Map<String, dynamic>> createOneTimePaymentIntentOnConnectedAccount({
    required String facilityId,
    required String tenantId,
    required int amountCents,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Creating one-time PaymentIntent on connected account: \$${amountCents / 100}');
      }
      final callable = _functions.httpsCallable('createOneTimePaymentIntentOnConnectedAccount');
      final result = await callable.call(<String, dynamic>{
        'facilityId': facilityId,
        'tenantId': tenantId,
        'amountCents': amountCents,
      });
      final data = result.data as Map<String, dynamic>? ?? {};
      if (kDebugMode) {
        print('✅ One-time PaymentIntent created on connected account');
      }
      return data;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating one-time PaymentIntent: $e');
      }
      rethrow;
    }
  }

  /// Charge a tenant off-session using a stored payment method on a connected account
  /// Feature-flagged: Requires tenantAutopayEnabledGlobal OR facilityId in allowlist
  static Future<Map<String, dynamic>> chargeTenantOffSession({
    required String facilityId,
    required String tenantId,
    required String paymentMethodId,
    required double amount,
    String? description,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Charging tenant off-session on connected account: \$$amount');
      }

      final callable = _functions.httpsCallable('chargeTenantOffSession');
      final result = await callable.call(<String, dynamic>{
        'facilityId': facilityId,
        'tenantId': tenantId,
        'paymentMethodId': paymentMethodId,
        'amount': amount,
        'description': description,
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      final success = data['success'] as bool? ?? false;
      final paymentIntentId = data['paymentIntentId'] as String?;
      final status = data['status'] as String?;
      final recordingWarning = data['recordingWarning'] as String?;

      if (!success || paymentIntentId == null) {
        throw Exception('Failed to charge tenant');
      }

      if (kDebugMode) {
        print('✅ Tenant charged successfully: $paymentIntentId');
      }

      return {
        'success': true,
        'paymentIntentId': paymentIntentId,
        'status': status,
        'amount': amount,
        if (recordingWarning != null && recordingWarning.isNotEmpty)
          'recordingWarning': recordingWarning,
      };
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error charging tenant off-session: $e');
      }
      rethrow;
    }
  }

  /// Create a one-time PaymentIntent for store checkout (locks/boxes) on connected account
  /// Feature-flagged: Requires storeEnabledGlobal OR facilityId in allowlist
  static Future<Map<String, dynamic>> createStoreCheckout({
    required String facilityId,
    required List<Map<String, dynamic>> lineItems,
    String? customerEmail,
    String? customerName,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Creating store checkout on connected account: $facilityId');
      }

      final callable = _functions.httpsCallable('createStoreCheckout');
      final result = await callable.call(<String, dynamic>{
        'facilityId': facilityId,
        'lineItems': lineItems,
        'customerEmail': customerEmail,
        'customerName': customerName,
      });

      final clientSecret = result.data['clientSecret'] as String?;
      final paymentIntentId = result.data['paymentIntentId'] as String?;
      final saleId = result.data['saleId'] as String?;
      final amount = result.data['amount'] as double?;

      if (clientSecret == null || paymentIntentId == null) {
        throw Exception('Failed to create store checkout');
      }

      if (kDebugMode) {
        print('✅ Store checkout created: $paymentIntentId');
      }

      return {
        'clientSecret': clientSecret,
        'paymentIntentId': paymentIntentId,
        'saleId': saleId,
        'amount': amount,
      };
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating store checkout: $e');
      }
      rethrow;
    }
  }
}

