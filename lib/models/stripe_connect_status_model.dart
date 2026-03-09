import 'package:cloud_firestore/cloud_firestore.dart';

/// Facility-level Stripe Connect state. Gates tenant payment UI; only [StripeConnectState.enabled] allows card entry.
enum StripeConnectState {
  disconnected,
  onboardingIncomplete,
  enabled,
  actionRequired,
}

extension StripeConnectStateX on StripeConnectState {
  String get value {
    switch (this) {
      case StripeConnectState.disconnected:
        return 'DISCONNECTED';
      case StripeConnectState.onboardingIncomplete:
        return 'ONBOARDING_INCOMPLETE';
      case StripeConnectState.enabled:
        return 'ENABLED';
      case StripeConnectState.actionRequired:
        return 'ACTION_REQUIRED';
    }
  }

  static StripeConnectState fromString(String? v) {
    switch (v) {
      case 'DISCONNECTED':
        return StripeConnectState.disconnected;
      case 'ONBOARDING_INCOMPLETE':
        return StripeConnectState.onboardingIncomplete;
      case 'ENABLED':
        return StripeConnectState.enabled;
      case 'ACTION_REQUIRED':
        return StripeConnectState.actionRequired;
      default:
        return StripeConnectState.disconnected;
    }
  }
}

/// Persisted stripeStatus on facility doc and response from stripeConnectGetStatus.
class StripeConnectStatusModel {
  final StripeConnectState state;
  final bool chargesEnabled;
  final bool payoutsEnabled;
  final bool detailsSubmitted;
  final List<String> currentlyDue;
  final List<String> pastDue;
  final DateTime? updatedAt;

  const StripeConnectStatusModel({
    required this.state,
    required this.chargesEnabled,
    required this.payoutsEnabled,
    required this.detailsSubmitted,
    this.currentlyDue = const [],
    this.pastDue = const [],
    this.updatedAt,
  });

  bool get isEnabled => state == StripeConnectState.enabled;

  factory StripeConnectStatusModel.fromMap(Map<String, dynamic>? data) {
    if (data == null) {
      return const StripeConnectStatusModel(
        state: StripeConnectState.disconnected,
        chargesEnabled: false,
        payoutsEnabled: false,
        detailsSubmitted: false,
      );
    }
    final stateRaw = data['state'] as String?;
    final list = (dynamic value) {
      if (value is List) return value.map((e) => e.toString()).toList();
      return <String>[];
    };
    return StripeConnectStatusModel(
      state: StripeConnectStateX.fromString(stateRaw),
      chargesEnabled: data['chargesEnabled'] == true,
      payoutsEnabled: data['payoutsEnabled'] == true,
      detailsSubmitted: data['detailsSubmitted'] == true,
      currentlyDue: list(data['currentlyDue']),
      pastDue: list(data['pastDue']),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'state': state.value,
      'chargesEnabled': chargesEnabled,
      'payoutsEnabled': payoutsEnabled,
      'detailsSubmitted': detailsSubmitted,
      'currentlyDue': currentlyDue,
      'pastDue': pastDue,
    };
  }
}
