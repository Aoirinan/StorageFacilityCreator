import 'package:cloud_firestore/cloud_firestore.dart';

enum FlagRiskLevel { low, medium, high }

class FeatureFlagModel {
  final String key;
  final String label;
  final String description;
  final bool enabled;
  final FlagRiskLevel riskLevel;
  final DateTime? updatedAt;
  final String? updatedBy;

  const FeatureFlagModel({
    required this.key,
    required this.label,
    required this.description,
    required this.enabled,
    required this.riskLevel,
    this.updatedAt,
    this.updatedBy,
  });

  FeatureFlagModel copyWith(
      {bool? enabled, DateTime? updatedAt, String? updatedBy}) {
    return FeatureFlagModel(
      key: key,
      label: label,
      description: description,
      enabled: enabled ?? this.enabled,
      riskLevel: riskLevel,
      updatedAt: updatedAt ?? this.updatedAt,
      updatedBy: updatedBy ?? this.updatedBy,
    );
  }

  static FlagRiskLevel _riskFromString(String? s) {
    switch (s) {
      case 'high':
        return FlagRiskLevel.high;
      case 'medium':
        return FlagRiskLevel.medium;
      default:
        return FlagRiskLevel.low;
    }
  }

  static String _riskToString(FlagRiskLevel r) {
    switch (r) {
      case FlagRiskLevel.high:
        return 'high';
      case FlagRiskLevel.medium:
        return 'medium';
      case FlagRiskLevel.low:
        return 'low';
    }
  }

  factory FeatureFlagModel.fromMap(String key, Map<String, dynamic> data) {
    return FeatureFlagModel(
      key: key,
      label: data['label'] as String? ?? key,
      description: data['description'] as String? ?? '',
      enabled: data['enabled'] as bool? ?? true,
      riskLevel: _riskFromString(data['riskLevel'] as String?),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      updatedBy: data['updatedBy'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'label': label,
      'description': description,
      'enabled': enabled,
      'riskLevel': _riskToString(riskLevel),
      'updatedAt': updatedAt != null
          ? Timestamp.fromDate(updatedAt!)
          : FieldValue.serverTimestamp(),
      'updatedBy': updatedBy,
    };
  }
}

/// Default flag definitions — used to seed Firestore and as fallback when doc is missing.
final List<FeatureFlagModel> kDefaultFeatureFlags = [
  const FeatureFlagModel(
    key: 'TEXTING_ONBOARDING_V1',
    label: 'Texting Onboarding V1',
    description: 'Enables self-serve Twilio A2P 10DLC texting setup wizard.',
    enabled: false,
    riskLevel: FlagRiskLevel.high,
  ),
  const FeatureFlagModel(
    key: 'aiAssistant',
    label: 'AI Assistant',
    description: 'Enables the AI-powered assistant for all facilities.',
    enabled: true,
    riskLevel: FlagRiskLevel.low,
  ),
  const FeatureFlagModel(
    key: 'stripeConnect',
    label: 'Stripe Connect Payments',
    description: 'Allows facilities to collect payments via Stripe Connect.',
    enabled: true,
    riskLevel: FlagRiskLevel.high,
  ),
  const FeatureFlagModel(
    key: 'tenantPortal',
    label: 'Tenant Self-Service Portal',
    description:
        'Enables the public tenant portal for online payments and documents.',
    enabled: true,
    riskLevel: FlagRiskLevel.medium,
  ),
  const FeatureFlagModel(
    key: 'twoFactorAuth',
    label: '2FA Authentication',
    description: 'Allows facility owners to enable two-factor authentication.',
    enabled: true,
    riskLevel: FlagRiskLevel.medium,
  ),
  const FeatureFlagModel(
    key: 'autoOverlock',
    label: 'Automated Overlock',
    description:
        'Enables automated unit overlocking based on delinquency rules.',
    enabled: true,
    riskLevel: FlagRiskLevel.medium,
  ),
  const FeatureFlagModel(
    key: 'docuSign',
    label: 'DocuSign E-Signature',
    description:
        'Enables DocuSign integration for electronic contract signing.',
    enabled: true,
    riskLevel: FlagRiskLevel.low,
  ),
  const FeatureFlagModel(
    key: 'smsMessaging',
    label: 'SMS Messaging (Twilio)',
    description: 'Enables SMS notifications and conversations via Twilio.',
    enabled: true,
    riskLevel: FlagRiskLevel.medium,
  ),
  const FeatureFlagModel(
    key: 'exportReports',
    label: 'Data Export & Reports',
    description: 'Allows exporting facility data and generating reports.',
    enabled: true,
    riskLevel: FlagRiskLevel.low,
  ),
  const FeatureFlagModel(
    key: 'globalDNR',
    label: 'Global Do-Not-Rent List',
    description: 'Enables the cross-facility global do-not-rent registry.',
    enabled: true,
    riskLevel: FlagRiskLevel.low,
  ),
  const FeatureFlagModel(
    key: 'maintenanceMode',
    label: 'Maintenance Mode',
    description:
        'Puts the entire app into read-only mode for all non-superadmin users. Use during deployments or critical fixes.',
    enabled: false,
    riskLevel: FlagRiskLevel.high,
  ),
];
