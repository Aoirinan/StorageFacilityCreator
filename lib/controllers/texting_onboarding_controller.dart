import 'package:flutter/foundation.dart';

import 'package:sfcapp/models/texting_onboarding_model.dart';
import 'package:sfcapp/services/texting_onboarding_service.dart';
import 'package:sfcapp/utils/error_message_helper.dart';

class TextingOnboardingController extends ChangeNotifier {
  final TextingOnboardingRepository repository;

  TextingOnboardingController({required this.repository});

  String? facilityId;
  TextingOnboardingSnapshot? snapshot;
  bool isLoading = false;
  bool isWorking = false;
  String? errorMessage;
  int step = 0;

  bool get showDashboard => snapshot?.shouldShowDashboard == true;
  bool get shouldPoll => snapshot?.isUnderReview == true;

  Future<void> load(String nextFacilityId) async {
    facilityId = nextFacilityId;
    snapshot = null;
    errorMessage = null;
    isLoading = true;
    notifyListeners();
    try {
      snapshot = await repository.getStatus(nextFacilityId);
      step = snapshot!.resumeStep;
    } catch (error) {
      errorMessage = ErrorMessageHelper.getUserFriendlyMessage(error);
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  void goToStep(int nextStep) {
    step = nextStep.clamp(0, 2);
    errorMessage = null;
    notifyListeners();
  }

  Future<bool> saveBusinessInfo(Map<String, dynamic> businessData) async {
    final id = facilityId;
    if (id == null) return false;
    return _runAction(() async {
      await repository.saveBusinessInfo(
        facilityId: id,
        businessData: businessData,
      );
      snapshot = await repository.getStatus(id);
      step = 1;
    });
  }

  void saveMessagingPlanLocally() {
    step = 2;
    errorMessage = null;
    notifyListeners();
  }

  Future<bool> provisionAndSubmit({
    required String? areaCode,
    required List<String> useCases,
    required List<String> sampleMessages,
  }) async {
    final id = facilityId;
    if (id == null) return false;
    return _runAction(() async {
      snapshot = await repository.provisionPhoneNumber(
        facilityId: id,
        areaCode: areaCode,
      );
      snapshot = await repository.submitOnboarding(
        facilityId: id,
        useCases: useCases,
        sampleMessages: sampleMessages,
      );
    });
  }

  Future<void> refresh({bool poll = false}) async {
    final id = facilityId;
    if (id == null || isWorking || (poll && !shouldPoll)) return;
    if (!poll) {
      await _runAction(() async {
        snapshot = await repository.refreshStatus(id);
      });
      return;
    }

    try {
      snapshot = await repository.refreshStatus(id);
      errorMessage = null;
      notifyListeners();
    } catch (_) {
      // Background polling is intentionally quiet; manual refresh exposes errors.
    }
  }

  Future<bool> resetAfterRejection() async {
    final id = facilityId;
    if (id == null) return false;
    return _runAction(() async {
      await repository.resubmit(id);
      snapshot = await repository.getStatus(id);
      step = snapshot!.resumeStep;
    });
  }

  Future<void> setPlatformApproval(bool approved) async {
    final id = facilityId;
    if (id == null) return;
    await _runAction(() async {
      await repository.setPlatformApproval(
        facilityId: id,
        approved: approved,
      );
      snapshot = await repository.getStatus(id);
    });
  }

  void clearError() {
    errorMessage = null;
    notifyListeners();
  }

  Future<bool> _runAction(Future<void> Function() action) async {
    if (isWorking) return false;
    isWorking = true;
    errorMessage = null;
    notifyListeners();
    try {
      await action();
      return true;
    } catch (error) {
      errorMessage = ErrorMessageHelper.getUserFriendlyMessage(error);
      return false;
    } finally {
      isWorking = false;
      notifyListeners();
    }
  }
}
