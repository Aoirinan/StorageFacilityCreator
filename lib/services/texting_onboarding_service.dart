import 'package:cloud_functions/cloud_functions.dart';

import 'package:sfcapp/models/texting_onboarding_model.dart';

abstract class TextingOnboardingRepository {
  Future<TextingOnboardingSnapshot> getStatus(String facilityId);

  Future<void> saveBusinessInfo({
    required String facilityId,
    required Map<String, dynamic> businessData,
  });

  Future<TextingOnboardingSnapshot> provisionPhoneNumber({
    required String facilityId,
    String? areaCode,
  });

  Future<TextingOnboardingSnapshot> submitOnboarding({
    required String facilityId,
    required List<String> useCases,
    required List<String> sampleMessages,
  });

  Future<TextingOnboardingSnapshot> refreshStatus(String facilityId);

  Future<void> resubmit(String facilityId);

  Future<void> setPlatformApproval({
    required String facilityId,
    required bool approved,
  });
}

class FirebaseTextingOnboardingRepository
    implements TextingOnboardingRepository {
  final FirebaseFunctions _functions;

  FirebaseTextingOnboardingRepository({FirebaseFunctions? functions})
      : _functions = functions ?? FirebaseFunctions.instance;

  @override
  Future<TextingOnboardingSnapshot> getStatus(String facilityId) async {
    final result =
        await _functions.httpsCallable('getTextingOnboardingStatus').call({
      'facilityId': facilityId,
    });
    return TextingOnboardingSnapshot.fromMap(
      Map<String, dynamic>.from(result.data as Map),
    );
  }

  @override
  Future<void> saveBusinessInfo({
    required String facilityId,
    required Map<String, dynamic> businessData,
  }) async {
    await _functions.httpsCallable('saveTextingBusinessInfo').call({
      'facilityId': facilityId,
      'businessData': businessData,
    });
  }

  @override
  Future<TextingOnboardingSnapshot> provisionPhoneNumber({
    required String facilityId,
    String? areaCode,
  }) async {
    await _functions.httpsCallable('provisionPhoneNumber').call({
      'facilityId': facilityId,
      if (areaCode != null && areaCode.isNotEmpty) 'areaCode': areaCode,
    });
    return getStatus(facilityId);
  }

  @override
  Future<TextingOnboardingSnapshot> submitOnboarding({
    required String facilityId,
    required List<String> useCases,
    required List<String> sampleMessages,
  }) async {
    await _functions.httpsCallable('submitTextingOnboarding').call({
      'facilityId': facilityId,
      'campaignData': {
        'useCases': useCases,
        'sampleMessages': sampleMessages,
        'consentConfirmed': true,
      },
    });
    return getStatus(facilityId);
  }

  @override
  Future<TextingOnboardingSnapshot> refreshStatus(String facilityId) async {
    await _functions
        .httpsCallable('refreshTextingOnboardingStatus')
        .call({'facilityId': facilityId});
    return getStatus(facilityId);
  }

  @override
  Future<void> resubmit(String facilityId) async {
    await _functions.httpsCallable('resubmitTextingOnboarding').call({
      'facilityId': facilityId,
    });
  }

  @override
  Future<void> setPlatformApproval({
    required String facilityId,
    required bool approved,
  }) async {
    await _functions.httpsCallable('setTextingPlatformApproval').call({
      'facilityId': facilityId,
      'approved': approved,
    });
  }
}

/// Backward-compatible static facade for callers outside the setup screen.
class TextingOnboardingService {
  static final TextingOnboardingRepository _repository =
      FirebaseTextingOnboardingRepository();

  static Future<TextingOnboardingSnapshot> getStatus(String facilityId) =>
      _repository.getStatus(facilityId);

  static Future<void> saveBusinessInfo({
    required String facilityId,
    required Map<String, dynamic> businessData,
  }) async {
    return _repository.saveBusinessInfo(
      facilityId: facilityId,
      businessData: businessData,
    );
  }

  static Future<TextingOnboardingSnapshot> provisionPhoneNumber({
    required String facilityId,
    String? areaCode,
  }) =>
      _repository.provisionPhoneNumber(
        facilityId: facilityId,
        areaCode: areaCode,
      );

  static Future<TextingOnboardingSnapshot> submitOnboarding({
    required String facilityId,
    required List<String> useCases,
    required List<String> sampleMessages,
  }) =>
      _repository.submitOnboarding(
        facilityId: facilityId,
        useCases: useCases,
        sampleMessages: sampleMessages,
      );

  static Future<TextingOnboardingSnapshot> refreshStatus(String facilityId) =>
      _repository.refreshStatus(facilityId);

  static Future<void> resubmit(String facilityId) async {
    return _repository.resubmit(facilityId);
  }

  static Future<void> setPlatformApproval({
    required String facilityId,
    required bool approved,
  }) async {
    return _repository.setPlatformApproval(
      facilityId: facilityId,
      approved: approved,
    );
  }
}
