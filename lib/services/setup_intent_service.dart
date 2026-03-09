import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Service for handling SetupIntent creation and payment method capture
/// PCI-safe: Only handles PaymentMethod IDs, never raw card data
class SetupIntentService {
  static final FirebaseFunctions _functions = FirebaseFunctions.instance;

  /// Create a SetupIntent for saving a payment method
  /// Returns clientSecret for use with Stripe Elements
  static Future<Map<String, dynamic>> createSetupIntent({
    required String facilityId,
    required String tenantId,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Creating SetupIntent for tenant: $tenantId');
      }

      final callable = _functions.httpsCallable('createSetupIntent');
      final result = await callable.call(<String, dynamic>{
        'facilityId': facilityId,
        'tenantId': tenantId,
      });

      final clientSecret = result.data['clientSecret'] as String?;
      final setupIntentId = result.data['setupIntentId'] as String?;

      if (clientSecret == null) {
        throw Exception('Failed to create setup intent');
      }

      if (kDebugMode) {
        print('✅ SetupIntent created: $setupIntentId');
      }

      return {
        'clientSecret': clientSecret,
        'setupIntentId': setupIntentId,
      };
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating SetupIntent: $e');
      }
      rethrow;
    }
  }

  /// Attach a payment method to a customer after SetupIntent confirmation
  /// Called after Stripe Elements confirms the SetupIntent
  static Future<Map<String, dynamic>> attachPaymentMethod({
    required String facilityId,
    required String tenantId,
    required String paymentMethodId,
    String? setupIntentId,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Attaching payment method: $paymentMethodId');
      }

      final callable = _functions.httpsCallable('attachPaymentMethod');
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
        throw Exception('Failed to attach payment method');
      }

      if (kDebugMode) {
        print('✅ Payment method attached: $paymentMethodDocId');
      }

      return {
        'success': true,
        'paymentMethodId': paymentMethodDocId,
        'displayInfo': displayInfo,
      };
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error attaching payment method: $e');
      }
      rethrow;
    }
  }

  /// Open Stripe card capture page in new window/iframe
  /// Returns payment method ID via postMessage or URL callback
  static Future<String?> openCardCapture({
    required String clientSecret,
    String? publishableKey,
    String? returnUrl,
  }) async {
    try {
      // Build URL with parameters
      final uri = Uri.parse('/stripe_card_capture.html').replace(
        queryParameters: {
          'clientSecret': clientSecret,
          if (publishableKey != null) 'publishableKey': publishableKey,
          if (returnUrl != null) 'returnUrl': returnUrl,
        },
      );

      // For web, we can use url_launcher or open in iframe
      // In a real implementation, you might want to use a dialog with iframe
      // For now, we'll use launchUrl which opens in a new window
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );

      if (!launched) {
        throw Exception('Failed to open card capture page');
      }

      // Note: In a real implementation, you'd listen for postMessage
      // or poll for the result. For now, this is a placeholder.
      // The actual implementation would use a WebView or iframe with message passing.
      return null;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error opening card capture: $e');
      }
      rethrow;
    }
  }

  /// Map Stripe error codes to user-friendly messages
  static String getErrorMessage(String errorCode, {String? message}) {
    switch (errorCode) {
      case 'card_declined':
        return 'Your card was declined. Please try another card or contact your bank.';
      case 'insufficient_funds':
        return 'Insufficient funds. Please use a different payment method.';
      case 'expired_card':
        return 'Your card has expired. Please use a different card.';
      case 'incorrect_cvc':
        return 'The security code is incorrect. Please check and try again.';
      case 'incorrect_number':
        return 'The card number is incorrect. Please check and try again.';
      case 'processing_error':
        return 'An error occurred while processing your card. Please try again.';
      case 'generic_decline':
        return 'Your card was declined. Please try another card.';
      case 'lost_card':
        return 'Your card was declined. Please contact your bank.';
      case 'stolen_card':
        return 'Your card was declined. Please contact your bank.';
      case 'pickup_card':
        return 'Your card was declined. Please contact your bank.';
      case 'restricted_card':
        return 'Your card was declined. Please contact your bank.';
      case 'security_violation':
        return 'Your card was declined due to a security violation. Please contact your bank.';
      case 'service_not_allowed':
        return 'This card type is not accepted. Please use a different card.';
      case 'do_not_honor':
        return 'Your card was declined. Please try another card or contact your bank.';
      default:
        return message ?? 'An error occurred. Please try again or contact support.';
    }
  }
}
