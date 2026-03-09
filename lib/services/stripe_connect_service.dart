import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import '../models/stripe_connect_status_model.dart';

/// Facility-level Stripe Connect status and onboarding.
/// Gate all tenant payment UI behind [StripeConnectState.enabled].
class StripeConnectService {
  static final _functions = FirebaseFunctions.instance;

  /// Opens Connect onboarding in a new tab. Creates account if missing, then returns URL.
  /// Call when state is DISCONNECTED or ONBOARDING_INCOMPLETE or ACTION_REQUIRED.
  static Future<String> connectOrFinishOnboarding(String facilityId) async {
    final result = await _functions.httpsCallable('createStripeConnectAccountLink').call({'facilityId': facilityId});
    final url = result.data['url'] as String?;
    if (url == null || url.isEmpty) {
      throw Exception('Failed to get onboarding URL');
    }
    return url;
  }

  /// Fetches current Connect status from backend (state machine + Stripe account).
  /// Call on tenant payment screen init and after "Refresh Status".
  static Future<StripeConnectStatusResult> refreshStatus(String facilityId) async {
    try {
      final result = await _functions.httpsCallable('stripeConnectGetStatus').call({'facilityId': facilityId});
      final data = result.data as Map<String, dynamic>;
      final stateStr = data['state'] as String?;
      final state = StripeConnectStateX.fromString(stateStr);
      final status = StripeConnectStatusModel.fromMap(Map<String, dynamic>.from(data));
      return StripeConnectStatusResult(
        state: state,
        status: status,
        connectedAccountId: data['connectedAccountId'] as String?,
      );
    } on FirebaseFunctionsException catch (e) {
      if (kDebugMode) {
        print('StripeConnectService.refreshStatus: $e');
      }
      rethrow;
    }
  }
}

class StripeConnectStatusResult {
  final StripeConnectState state;
  final StripeConnectStatusModel status;
  final String? connectedAccountId;

  StripeConnectStatusResult({
    required this.state,
    required this.status,
    this.connectedAccountId,
  });

  bool get isEnabled => state == StripeConnectState.enabled;
}
