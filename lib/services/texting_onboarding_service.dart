import 'package:cloud_functions/cloud_functions.dart';

class TextingOnboardingService {
  static final FirebaseFunctions _functions = FirebaseFunctions.instance;

  static Future<Map<String, dynamic>> getStatus(String facilityId) async {
    final result =
        await _functions.httpsCallable('getTextingOnboardingStatus').call({
      'facilityId': facilityId,
    });
    return Map<String, dynamic>.from(result.data as Map);
  }

  static Future<void> saveBusinessInfo({
    required String facilityId,
    required Map<String, dynamic> businessData,
  }) async {
    await _functions.httpsCallable('saveTextingBusinessInfo').call({
      'facilityId': facilityId,
      'businessData': businessData,
    });
  }

  static Future<Map<String, dynamic>> provisionPhoneNumber({
    required String facilityId,
    String? areaCode,
  }) async {
    final result = await _functions.httpsCallable('provisionPhoneNumber').call({
      'facilityId': facilityId,
      if (areaCode != null && areaCode.isNotEmpty) 'areaCode': areaCode,
    });
    return Map<String, dynamic>.from(result.data as Map);
  }

  static Future<Map<String, dynamic>> submitOnboarding({
    required String facilityId,
    required List<String> useCases,
    required List<String> sampleMessages,
  }) async {
    final result =
        await _functions.httpsCallable('submitTextingOnboarding').call({
      'facilityId': facilityId,
      'campaignData': {
        'useCases': useCases,
        'sampleMessages': sampleMessages,
        'consentConfirmed': true,
      },
    });
    return Map<String, dynamic>.from(result.data as Map);
  }

  static Future<Map<String, dynamic>> refreshStatus(String facilityId) async {
    final result =
        await _functions.httpsCallable('refreshTextingOnboardingStatus').call({
      'facilityId': facilityId,
    });
    return Map<String, dynamic>.from(result.data as Map);
  }

  static Future<void> resubmit(String facilityId) async {
    await _functions.httpsCallable('resubmitTextingOnboarding').call({
      'facilityId': facilityId,
    });
  }
}
