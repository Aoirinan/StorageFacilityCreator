import 'package:cloud_firestore/cloud_firestore.dart';

enum TextingRegistrationStatus {
  draft,
  submitted,
  pending,
  approved,
  rejected;

  static TextingRegistrationStatus fromValue(Object? value) {
    return TextingRegistrationStatus.values.firstWhere(
      (status) => status.name == value?.toString().toLowerCase(),
      orElse: () => TextingRegistrationStatus.draft,
    );
  }
}

class TextingBusinessDetails {
  final String legalBusinessName;
  final String? dba;
  final String businessType;
  final String? einLast4;
  final String addressLine1;
  final String city;
  final String state;
  final String postalCode;
  final String country;
  final String website;
  final String supportEmail;
  final String supportPhone;
  // Carrier vetting requires a named authorized representative for the brand.
  final String? representativeFirstName;
  final String? representativeLastName;
  final String? representativeBusinessTitle;

  const TextingBusinessDetails({
    required this.legalBusinessName,
    this.dba,
    required this.businessType,
    this.einLast4,
    required this.addressLine1,
    required this.city,
    required this.state,
    required this.postalCode,
    this.country = 'US',
    required this.website,
    required this.supportEmail,
    required this.supportPhone,
    this.representativeFirstName,
    this.representativeLastName,
    this.representativeBusinessTitle,
  });

  bool get isComplete =>
      legalBusinessName.isNotEmpty &&
      businessType.isNotEmpty &&
      addressLine1.isNotEmpty &&
      city.isNotEmpty &&
      state.isNotEmpty &&
      postalCode.isNotEmpty &&
      website.isNotEmpty &&
      supportEmail.isNotEmpty &&
      supportPhone.isNotEmpty &&
      (representativeFirstName ?? '').isNotEmpty &&
      (representativeLastName ?? '').isNotEmpty;

  factory TextingBusinessDetails.fromMap(Map<String, dynamic> map) {
    String value(String key) => (map[key] as String? ?? '').trim();
    final dba = value('dba');
    final einLast4 = value('einLast4');
    String? optional(String key) {
      final v = value(key);
      return v.isEmpty ? null : v;
    }

    return TextingBusinessDetails(
      legalBusinessName: value('legalBusinessName'),
      dba: dba.isEmpty ? null : dba,
      businessType: value('businessType'),
      einLast4: einLast4.isEmpty ? null : einLast4,
      addressLine1: value('addressLine1'),
      city: value('city'),
      state: value('state'),
      postalCode: value('postalCode'),
      country: value('country').isEmpty ? 'US' : value('country'),
      website: value('website'),
      supportEmail: value('supportEmail'),
      supportPhone: value('supportPhone'),
      representativeFirstName: optional('representativeFirstName'),
      representativeLastName: optional('representativeLastName'),
      representativeBusinessTitle: optional('representativeBusinessTitle'),
    );
  }
}

class TextingOnboardingSnapshot {
  final TextingRegistrationStatus status;
  final String? lastError;
  final String? rejectionReason;
  final bool platformApproved;
  final String? phoneNumber;
  final TextingBusinessDetails? businessDetails;
  final List<String> useCases;
  final List<String> sampleMessages;
  final DateTime? submittedAt;
  final DateTime? approvedAt;
  final DateTime? rejectedAt;
  final bool hasTrustProfile;

  const TextingOnboardingSnapshot({
    required this.status,
    this.lastError,
    this.rejectionReason,
    required this.platformApproved,
    this.phoneNumber,
    this.businessDetails,
    this.useCases = const [],
    this.sampleMessages = const [],
    this.submittedAt,
    this.approvedAt,
    this.rejectedAt,
    required this.hasTrustProfile,
  });

  bool get isUnderReview =>
      status == TextingRegistrationStatus.submitted ||
      status == TextingRegistrationStatus.pending;

  bool get isLive =>
      status == TextingRegistrationStatus.approved && platformApproved;

  bool get shouldShowDashboard =>
      status != TextingRegistrationStatus.draft ||
      platformApproved ||
      rejectedAt != null;

  int get resumeStep {
    if (!hasTrustProfile || businessDetails?.isComplete != true) return 0;
    if (useCases.isEmpty) return 1;
    return 2;
  }

  factory TextingOnboardingSnapshot.fromMap(Map<String, dynamic> map) {
    final businessMap = map['businessData'];
    return TextingOnboardingSnapshot(
      status: TextingRegistrationStatus.fromValue(map['a2pStatus']),
      lastError: map['a2pLastError'] as String?,
      rejectionReason: map['rejectionReason'] as String?,
      platformApproved: map['textingPlatformApproved'] == true,
      phoneNumber: map['twilioPhoneNumberE164'] as String?,
      businessDetails: businessMap is Map
          ? TextingBusinessDetails.fromMap(
              Map<String, dynamic>.from(businessMap),
            )
          : null,
      useCases: _stringList(map['useCases']),
      sampleMessages: _stringList(map['sampleMessages']),
      submittedAt: _dateTime(map['submittedAt']),
      approvedAt: _dateTime(map['approvedAt']),
      rejectedAt: _dateTime(map['rejectedAt']),
      hasTrustProfile: map['hasTrustProfile'] == true ||
          (map['twilioTrustProfileSid'] as String?)?.isNotEmpty == true,
    );
  }

  static List<String> _stringList(Object? value) {
    if (value is! List) return const [];
    return value.whereType<String>().toList(growable: false);
  }

  static DateTime? _dateTime(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is Map) {
      final seconds = value['_seconds'] ?? value['seconds'];
      if (seconds is int) {
        return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
      }
    }
    if (value is Timestamp) return value.toDate();
    return null;
  }
}
