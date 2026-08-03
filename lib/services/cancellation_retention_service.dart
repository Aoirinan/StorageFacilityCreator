import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import '../models/cancellation_retention_model.dart';

class CancellationIntentResult {
  final String eventId;
  final List<String> lossCopy;
  final List<CancellationPromo> promos;

  const CancellationIntentResult({
    required this.eventId,
    required this.lossCopy,
    required this.promos,
  });
}

class CancellationRetentionService {
  static final _functions = FirebaseFunctions.instance;

  static Future<CancellationRetentionConfig> getConfig() async {
    final callable = _functions.httpsCallable('getCancellationRetentionConfig');
    final result = await callable.call().timeout(const Duration(seconds: 30));
    final data = Map<String, dynamic>.from(result.data as Map);
    final configMap = Map<String, dynamic>.from(data['config'] as Map);
    return CancellationRetentionConfig.fromMap(configMap);
  }

  static Future<CancellationIntentResult> submitIntent({
    required String facilityId,
    required String planType,
    required String primaryReason,
    required String detailReason,
  }) async {
    final callable = _functions.httpsCallable('submitCancellationIntent');
    final result = await callable.call(<String, dynamic>{
      'facilityId': facilityId,
      'planType': planType,
      'primaryReason': primaryReason,
      'detailReason': detailReason,
    }).timeout(const Duration(seconds: 45));
    final data = Map<String, dynamic>.from(result.data as Map);
    final promos = (data['promos'] as List<dynamic>? ?? const [])
        .map((e) => CancellationPromo.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
    return CancellationIntentResult(
      eventId: (data['eventId'] ?? '').toString(),
      lossCopy: (data['lossCopy'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      promos: promos,
    );
  }

  static Future<String> acceptOffer({
    required String eventId,
    required String promoId,
  }) async {
    final callable =
        _functions.httpsCallable('acceptCancellationRetentionOffer');
    final result = await callable.call(<String, dynamic>{
      'eventId': eventId,
      'promoId': promoId,
    }).timeout(const Duration(seconds: 60));
    final data = Map<String, dynamic>.from(result.data as Map);
    return (data['message'] ?? 'Offer applied.').toString();
  }

  static Future<String> confirmCancel({required String eventId}) async {
    final callable =
        _functions.httpsCallable('confirmCancellationAfterSurvey');
    final result = await callable.call(<String, dynamic>{
      'eventId': eventId,
    }).timeout(const Duration(seconds: 60));
    final data = Map<String, dynamic>.from(result.data as Map);
    return (data['message'] ?? 'Subscription will cancel at period end.')
        .toString();
  }

  static Future<CancellationRetentionConfig> upsertConfig(
    CancellationRetentionConfig config,
  ) async {
    final callable =
        _functions.httpsCallable('superAdminUpsertCancellationRetentionConfig');
    final result = await callable.call(<String, dynamic>{
      'config': config.toMap(),
    }).timeout(const Duration(seconds: 90));
    final data = Map<String, dynamic>.from(result.data as Map);
    return CancellationRetentionConfig.fromMap(
      Map<String, dynamic>.from(data['config'] as Map),
    );
  }

  static Future<List<CancellationEventRow>> listEvents({
    String planType = 'all',
    int limit = 200,
  }) async {
    final callable =
        _functions.httpsCallable('superAdminListCancellationEvents');
    final result = await callable.call(<String, dynamic>{
      'planType': planType,
      'limit': limit,
    }).timeout(const Duration(seconds: 60));
    final data = Map<String, dynamic>.from(result.data as Map);
    return (data['events'] as List<dynamic>? ?? const [])
        .map((e) =>
            CancellationEventRow.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  static Future<void> cancelWebsiteSubscription({
    required String facilityId,
  }) async {
    try {
      final callable = _functions.httpsCallable('cancelWebsiteSubscription');
      await callable.call(<String, dynamic>{'facilityId': facilityId}).timeout(
        const Duration(seconds: 60),
      );
    } catch (e) {
      if (kDebugMode) print('❌ cancelWebsiteSubscription: $e');
      rethrow;
    }
  }
}
