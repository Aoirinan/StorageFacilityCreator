/// Model for SMS usage tracking
class SMSUsage {
  final int currentCount;
  final int monthlyLimit;
  final String month;
  final DateTime? lastUpdated;

  SMSUsage({
    required this.currentCount,
    required this.monthlyLimit,
    required this.month,
    this.lastUpdated,
  });

  double get percentage => monthlyLimit > 0 ? (currentCount / monthlyLimit) * 100 : 0.0;
  bool get isApproaching => percentage >= 80 && percentage < 100;
  bool get isExceeded => percentage >= 100;
  bool get isExtreme => percentage >= 300; // 3x limit
  bool get canSend => !isExceeded && !isExtreme;

  @override
  String toString() {
    return 'SMSUsage(count: $currentCount/$monthlyLimit, ${percentage.toStringAsFixed(1)}%)';
  }
}

/// SMS usage state
enum SMSUsageState {
  normal,
  approaching, // 80-100% of limit
  exceeded, // Over 100% of limit
  extreme, // 3x limit
}

/// Complete SMS usage status for a facility
class SMSUsageStatus {
  final SMSUsageState state;
  final SMSUsage? tenantUsage;
  final SMSUsage facilityUsage;
  final SMSUsage? accountUsage;
  final bool canSendSMS;
  final bool shouldFallbackToEmail;
  final String? warningMessage;

  SMSUsageStatus({
    required this.state,
    this.tenantUsage,
    required this.facilityUsage,
    this.accountUsage,
    required this.canSendSMS,
    required this.shouldFallbackToEmail,
    this.warningMessage,
  });

  String get stateDescription {
    switch (state) {
      case SMSUsageState.normal:
        return 'Normal usage';
      case SMSUsageState.approaching:
        return 'Approaching limit';
      case SMSUsageState.exceeded:
        return 'Limit exceeded';
      case SMSUsageState.extreme:
        return 'Extreme usage';
    }
  }

  String get fairUseExplanation =>
      'SMS is included in your plan with fair-use limits to keep costs low for all SFC customers. '
      'If you exceed typical usage, automated messages will be sent via email instead. '
      'You will never be charged extra.';
}

