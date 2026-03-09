import 'package:flutter/foundation.dart';
import 'package:cloud_functions/cloud_functions.dart';

/// Service for managing Stripe Elements on Flutter web
/// 
/// This service provides a bridge between Flutter and Stripe.js
/// for collecting payment methods securely without redirecting to Stripe-hosted pages.
class StripeElementsService {
  static bool _isInitialized = false;
  static String? _publishableKey;

  /// Initialize Stripe with publishable key
  /// 
  /// Must be called before using any Stripe Elements features.
  static Future<void> initialize({required String publishableKey}) async {
    if (kIsWeb) {
      _publishableKey = publishableKey;
      _isInitialized = true;
      
      if (kDebugMode) {
        final mode = publishableKey.startsWith('pk_live_') ? 'LIVE' : 'TEST';
        print('✅ [StripeElements] Initialized with platform key (mode: $mode)');
      }
    } else {
      if (kDebugMode) {
        print('⚠️ [StripeElements] Stripe Elements only available on web platform');
      }
    }
  }

  /// Check if Stripe Elements is initialized
  static bool get isInitialized => _isInitialized && kIsWeb;

  /// Get publishable key
  static String? get publishableKey => _publishableKey;

  /// Create Payment Intent on backend (via Cloud Function)
  /// 
  /// This should be called to create a payment intent before collecting
  /// payment method from user.
  static Future<String?> createPaymentIntent({
    required String facilityId,
    required String tenantId,
    required double amount,
    String? currency = 'usd',
    String? description,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      // Call Cloud Function to create payment intent
      // This will be implemented when Cloud Function is created
      // For now, return null to indicate not implemented
      
      if (kDebugMode) {
        print('🔄 [StripeElements] Creating payment intent for amount: $amount');
        print('   This requires Cloud Function: createPaymentIntent');
      }
      
      return null;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [StripeElements] Error creating payment intent: $e');
      }
      rethrow;
    }
  }

  /// Confirm payment with Payment Intent (3D Secure handling)
  /// 
  /// This confirms the payment after collecting payment method.
  /// Handles 3D Secure authentication if required.
  static Future<Map<String, dynamic>> confirmPayment({
    required String paymentIntentClientSecret,
    required String paymentMethodId,
  }) async {
    try {
      // Call Cloud Function or use JavaScript interop to confirm payment
      // This will handle 3D Secure authentication
      
      if (kDebugMode) {
        print('🔄 [StripeElements] Confirming payment with method: $paymentMethodId');
        print('   This requires JavaScript interop with Stripe.js');
      }
      
      // Return success for now (will be implemented with JS interop)
      return {
        'success': false,
        'error': 'Payment confirmation not yet implemented. Requires JavaScript interop.',
      };
    } catch (e) {
      if (kDebugMode) {
        print('❌ [StripeElements] Error confirming payment: $e');
      }
      return {
        'success': false,
        'error': 'Failed to confirm payment: $e',
      };
    }
  }

  /// Attach payment method to customer
  /// 
  /// This attaches a payment method to a Stripe customer.
  static Future<String?> attachPaymentMethodToCustomer({
    required String paymentMethodId,
    required String customerId,
  }) async {
    try {
      // Call Cloud Function to attach payment method
      // This will be implemented when Cloud Function is created
      
      if (kDebugMode) {
        print('🔄 [StripeElements] Attaching payment method to customer');
        print('   Payment Method: $paymentMethodId');
        print('   Customer: $customerId');
        print('   This requires Cloud Function: attachPaymentMethodToCustomer');
      }
      
      return null;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [StripeElements] Error attaching payment method: $e');
      }
      return null;
    }
  }

  /// Get Stripe publishable key from Cloud Function
  /// 
  /// Fetches the publishable key from the backend if not already initialized.
  static Future<String?> getPublishableKey() async {
    // If already initialized, return cached key
    if (_publishableKey != null && _publishableKey!.isNotEmpty) {
      return _publishableKey;
    }
    
    // Try to fetch from Cloud Function
    try {
      final functions = FirebaseFunctions.instance;
      final result = await functions.httpsCallable('getStripePublishableKey').call();
      final data = result.data as Map<String, dynamic>?;
      final key = data?['publishableKey'] as String?;
      
      if (key != null && key.isNotEmpty) {
        _publishableKey = key;
        _isInitialized = true;
        if (kDebugMode) {
          print('✅ [StripeElements] Fetched publishable key from Cloud Function');
        }
        return key;
      }
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ [StripeElements] Failed to fetch publishable key from Cloud Function: $e');
      }
    }
    
    // Fallback to cached key (if initialized manually)
    return _publishableKey;
  }
}

