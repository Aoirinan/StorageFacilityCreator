import 'package:cloud_firestore/cloud_firestore.dart';
import 'stripe_connect_status_model.dart';

class FacilityModel {
  final String id;
  final String name;
  final String? logoUrl;
  final String ownerUid;
  final String?
      facilityCreatorAccountId; // Link to Facility Creator Account (for SaaS model)
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String? address;
  final String? phone;
  final String? email;
  final String? description;
  final int totalUnits;
  final int occupiedUnits;
  final bool active; // Added for soft delete
  final DateTime? archivedAt; // Added for soft delete
  final String? archivedByUid; // Added for soft delete

  // Billing and operational settings
  final String? timeZone; // e.g., "America/New_York"
  final Map<String, dynamic>? businessHours; // Map with days/hours
  final Map<String, dynamic>? gateHours; // Map with days/hours
  final Map<String, dynamic>?
      billingSettings; // Late fee rules, tax rate, grace period
  final Map<String, dynamic>?
      insuranceSettings; // TPP settings, auto-enrollment rules

  // Stripe Connect integration
  final String? stripeConnectAccountId; // Connected Stripe account ID
  final bool stripeConnectOnboardingComplete; // Whether onboarding is complete
  final StripeConnectStatusModel?
      stripeStatus; // State machine: DISCONNECTED | ONBOARDING_INCOMPLETE | ENABLED | ACTION_REQUIRED

  // Per-facility platform subscription ($75/mo, own card per facility)
  final String? stripePlatformSubscriptionId;
  final String?
      platformSubscriptionStatus; // active | trialing | past_due | cancelled | unpaid
  final DateTime? platformSubscriptionCurrentPeriodEnd;
  final bool platformSubscriptionCancelAtPeriodEnd;

  // Localization
  final String?
      defaultLocale; // Default language/locale for facility (e.g., "en_US", "es_ES")

  // SMS Settings (optional, backward compatible)
  final Map<String, dynamic>? smsSettings; // SMS compliance settings
  final bool textingOnboardingEnabled;
  final String? a2pStatus;
  final String? a2pLastError;
  final bool textingPlatformApproved;
  final DateTime? textingPlatformApprovedAt;
  final String? textingPlatformApprovedBy;
  final String? twilioMessagingServiceSid;
  final String? twilioTrustProfileSid;
  final String? twilioTrustProductSid;
  final String? twilioBrandSid;
  final String? twilioCampaignSid;
  final String? twilioPhoneNumberSid;
  final String? twilioPhoneNumberE164;

  FacilityModel({
    required this.id,
    required this.name,
    this.logoUrl,
    required this.ownerUid,
    this.facilityCreatorAccountId,
    required this.createdAt,
    this.updatedAt,
    this.address,
    this.phone,
    this.email,
    this.description,
    this.totalUnits = 0,
    this.occupiedUnits = 0,
    this.active = true, // Default to active
    this.archivedAt,
    this.archivedByUid,
    this.timeZone,
    this.businessHours,
    this.gateHours,
    this.billingSettings,
    this.insuranceSettings,
    this.stripeConnectAccountId,
    this.stripeConnectOnboardingComplete = false,
    this.stripeStatus,
    this.stripePlatformSubscriptionId,
    this.platformSubscriptionStatus,
    this.platformSubscriptionCurrentPeriodEnd,
    this.platformSubscriptionCancelAtPeriodEnd = false,
    this.defaultLocale,
    this.smsSettings,
    this.textingOnboardingEnabled = false,
    this.a2pStatus,
    this.a2pLastError,
    this.textingPlatformApproved = false,
    this.textingPlatformApprovedAt,
    this.textingPlatformApprovedBy,
    this.twilioMessagingServiceSid,
    this.twilioTrustProfileSid,
    this.twilioTrustProductSid,
    this.twilioBrandSid,
    this.twilioCampaignSid,
    this.twilioPhoneNumberSid,
    this.twilioPhoneNumberE164,
  });

  // Create FacilityModel from Firestore document
  factory FacilityModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;

    return FacilityModel(
      id: doc.id,
      name: data?['name'] ?? '',
      logoUrl: data?['logoUrl'],
      ownerUid: data?['ownerUid'] ?? '',
      facilityCreatorAccountId: data?['facilityCreatorAccountId'],
      createdAt: (data?['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data?['updatedAt'] as Timestamp?)?.toDate(),
      address: data?['address'],
      phone: data?['phone'],
      email: data?['email'],
      description: data?['description'],
      totalUnits: data?['totalUnits'] ?? 0,
      occupiedUnits: data?['occupiedUnits'] ?? 0,
      active: data?['active'] ?? true, // Default to active if not specified
      archivedAt: (data?['archivedAt'] as Timestamp?)?.toDate(),
      archivedByUid: data?['archivedByUid'],
      timeZone: data?['timeZone'],
      businessHours: data?['businessHours'] != null
          ? Map<String, dynamic>.from(data!['businessHours'])
          : null,
      gateHours: data?['gateHours'] != null
          ? Map<String, dynamic>.from(data!['gateHours'])
          : null,
      billingSettings: data?['billingSettings'] != null
          ? Map<String, dynamic>.from(data!['billingSettings'])
          : null,
      insuranceSettings: data?['insuranceSettings'] != null
          ? Map<String, dynamic>.from(data!['insuranceSettings'])
          : null,
      stripeConnectAccountId: data?['stripeConnectAccountId'],
      stripeConnectOnboardingComplete:
          data?['stripeConnectOnboardingComplete'] ?? false,
      stripeStatus: data?['stripeStatus'] != null
          ? StripeConnectStatusModel.fromMap(
              Map<String, dynamic>.from(data!['stripeStatus'] as Map))
          : null,
      stripePlatformSubscriptionId:
          data?['stripePlatformSubscriptionId'] as String?,
      platformSubscriptionStatus:
          data?['platformSubscriptionStatus'] as String?,
      platformSubscriptionCurrentPeriodEnd:
          (data?['platformSubscriptionCurrentPeriodEnd'] as Timestamp?)
              ?.toDate(),
      platformSubscriptionCancelAtPeriodEnd:
          data?['platformSubscriptionCancelAtPeriodEnd'] ?? false,
      defaultLocale: data?['defaultLocale'] as String?,
      smsSettings: data?['smsSettings'] != null
          ? Map<String, dynamic>.from(data!['smsSettings'])
          : null,
      textingOnboardingEnabled: data?['textingOnboardingEnabled'] ?? false,
      a2pStatus: data?['a2pStatus'] as String?,
      a2pLastError: data?['a2pLastError'] as String?,
      textingPlatformApproved: data?['textingPlatformApproved'] == true,
      textingPlatformApprovedAt:
          (data?['textingPlatformApprovedAt'] as Timestamp?)?.toDate(),
      textingPlatformApprovedBy: data?['textingPlatformApprovedBy'] as String?,
      twilioMessagingServiceSid: data?['twilioMessagingServiceSid'] as String?,
      twilioTrustProfileSid: data?['twilioTrustProfileSid'] as String?,
      twilioTrustProductSid: data?['twilioTrustProductSid'] as String?,
      twilioBrandSid: data?['twilioBrandSid'] as String?,
      twilioCampaignSid: data?['twilioCampaignSid'] as String?,
      twilioPhoneNumberSid: data?['twilioPhoneNumberSid'] as String?,
      twilioPhoneNumberE164: data?['twilioPhoneNumberE164'] as String?,
    );
  }

  // Convert FacilityModel to Map for Firestore
  Map<String, dynamic> toFirestore() {
    return {
      'name': name,
      'logoUrl': logoUrl,
      'ownerUid': ownerUid,
      'facilityCreatorAccountId': facilityCreatorAccountId,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': updatedAt != null
          ? Timestamp.fromDate(updatedAt!)
          : FieldValue.serverTimestamp(),
      'address': address,
      'phone': phone,
      'email': email,
      'description': description,
      'totalUnits': totalUnits,
      'occupiedUnits': occupiedUnits,
      'active': active,
      'archivedAt': archivedAt != null ? Timestamp.fromDate(archivedAt!) : null,
      'archivedByUid': archivedByUid,
      'timeZone': timeZone,
      'businessHours': businessHours,
      'gateHours': gateHours,
      'billingSettings': billingSettings,
      'insuranceSettings': insuranceSettings,
      'stripeConnectAccountId': stripeConnectAccountId,
      'stripeConnectOnboardingComplete': stripeConnectOnboardingComplete,
      if (stripeStatus != null) 'stripeStatus': stripeStatus!.toMap(),
      if (stripePlatformSubscriptionId != null)
        'stripePlatformSubscriptionId': stripePlatformSubscriptionId,
      if (platformSubscriptionStatus != null)
        'platformSubscriptionStatus': platformSubscriptionStatus,
      if (platformSubscriptionCurrentPeriodEnd != null)
        'platformSubscriptionCurrentPeriodEnd':
            Timestamp.fromDate(platformSubscriptionCurrentPeriodEnd!),
      'platformSubscriptionCancelAtPeriodEnd':
          platformSubscriptionCancelAtPeriodEnd,
      'defaultLocale': defaultLocale,
      if (smsSettings != null) 'smsSettings': smsSettings,
      'textingOnboardingEnabled': textingOnboardingEnabled,
      if (a2pStatus != null) 'a2pStatus': a2pStatus,
      if (a2pLastError != null) 'a2pLastError': a2pLastError,
      'textingPlatformApproved': textingPlatformApproved,
      if (textingPlatformApprovedAt != null)
        'textingPlatformApprovedAt':
            Timestamp.fromDate(textingPlatformApprovedAt!),
      if (textingPlatformApprovedBy != null)
        'textingPlatformApprovedBy': textingPlatformApprovedBy,
      if (twilioMessagingServiceSid != null)
        'twilioMessagingServiceSid': twilioMessagingServiceSid,
      if (twilioTrustProfileSid != null)
        'twilioTrustProfileSid': twilioTrustProfileSid,
      if (twilioTrustProductSid != null)
        'twilioTrustProductSid': twilioTrustProductSid,
      if (twilioBrandSid != null) 'twilioBrandSid': twilioBrandSid,
      if (twilioCampaignSid != null) 'twilioCampaignSid': twilioCampaignSid,
      if (twilioPhoneNumberSid != null)
        'twilioPhoneNumberSid': twilioPhoneNumberSid,
      if (twilioPhoneNumberE164 != null)
        'twilioPhoneNumberE164': twilioPhoneNumberE164,
    };
  }

  // Copy with method for updates
  FacilityModel copyWith({
    String? id,
    String? name,
    String? logoUrl,
    String? ownerUid,
    String? facilityCreatorAccountId,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? address,
    String? phone,
    String? email,
    String? description,
    int? totalUnits,
    int? occupiedUnits,
    bool? active,
    DateTime? archivedAt,
    String? archivedByUid,
    String? timeZone,
    Map<String, dynamic>? businessHours,
    Map<String, dynamic>? gateHours,
    Map<String, dynamic>? billingSettings,
    Map<String, dynamic>? insuranceSettings,
    String? stripeConnectAccountId,
    bool? stripeConnectOnboardingComplete,
    StripeConnectStatusModel? stripeStatus,
    String? stripePlatformSubscriptionId,
    String? platformSubscriptionStatus,
    DateTime? platformSubscriptionCurrentPeriodEnd,
    bool? platformSubscriptionCancelAtPeriodEnd,
    String? defaultLocale,
    Map<String, dynamic>? smsSettings,
    bool? textingOnboardingEnabled,
    String? a2pStatus,
    String? a2pLastError,
    bool? textingPlatformApproved,
    DateTime? textingPlatformApprovedAt,
    String? textingPlatformApprovedBy,
    String? twilioMessagingServiceSid,
    String? twilioTrustProfileSid,
    String? twilioTrustProductSid,
    String? twilioBrandSid,
    String? twilioCampaignSid,
    String? twilioPhoneNumberSid,
    String? twilioPhoneNumberE164,
  }) {
    return FacilityModel(
      id: id ?? this.id,
      name: name ?? this.name,
      logoUrl: logoUrl ?? this.logoUrl,
      ownerUid: ownerUid ?? this.ownerUid,
      facilityCreatorAccountId:
          facilityCreatorAccountId ?? this.facilityCreatorAccountId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      address: address ?? this.address,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      description: description ?? this.description,
      totalUnits: totalUnits ?? this.totalUnits,
      occupiedUnits: occupiedUnits ?? this.occupiedUnits,
      active: active ?? this.active,
      archivedAt: archivedAt ?? this.archivedAt,
      archivedByUid: archivedByUid ?? this.archivedByUid,
      timeZone: timeZone ?? this.timeZone,
      businessHours: businessHours ?? this.businessHours,
      gateHours: gateHours ?? this.gateHours,
      billingSettings: billingSettings ?? this.billingSettings,
      insuranceSettings: insuranceSettings ?? this.insuranceSettings,
      stripeConnectAccountId:
          stripeConnectAccountId ?? this.stripeConnectAccountId,
      stripeConnectOnboardingComplete: stripeConnectOnboardingComplete ??
          this.stripeConnectOnboardingComplete,
      stripeStatus: stripeStatus ?? this.stripeStatus,
      stripePlatformSubscriptionId:
          stripePlatformSubscriptionId ?? this.stripePlatformSubscriptionId,
      platformSubscriptionStatus:
          platformSubscriptionStatus ?? this.platformSubscriptionStatus,
      platformSubscriptionCurrentPeriodEnd:
          platformSubscriptionCurrentPeriodEnd ??
              this.platformSubscriptionCurrentPeriodEnd,
      platformSubscriptionCancelAtPeriodEnd:
          platformSubscriptionCancelAtPeriodEnd ??
              this.platformSubscriptionCancelAtPeriodEnd,
      defaultLocale: defaultLocale ?? this.defaultLocale,
      smsSettings: smsSettings ?? this.smsSettings,
      textingOnboardingEnabled:
          textingOnboardingEnabled ?? this.textingOnboardingEnabled,
      a2pStatus: a2pStatus ?? this.a2pStatus,
      a2pLastError: a2pLastError ?? this.a2pLastError,
      textingPlatformApproved:
          textingPlatformApproved ?? this.textingPlatformApproved,
      textingPlatformApprovedAt:
          textingPlatformApprovedAt ?? this.textingPlatformApprovedAt,
      textingPlatformApprovedBy:
          textingPlatformApprovedBy ?? this.textingPlatformApprovedBy,
      twilioMessagingServiceSid:
          twilioMessagingServiceSid ?? this.twilioMessagingServiceSid,
      twilioTrustProfileSid:
          twilioTrustProfileSid ?? this.twilioTrustProfileSid,
      twilioTrustProductSid:
          twilioTrustProductSid ?? this.twilioTrustProductSid,
      twilioBrandSid: twilioBrandSid ?? this.twilioBrandSid,
      twilioCampaignSid: twilioCampaignSid ?? this.twilioCampaignSid,
      twilioPhoneNumberSid: twilioPhoneNumberSid ?? this.twilioPhoneNumberSid,
      twilioPhoneNumberE164:
          twilioPhoneNumberE164 ?? this.twilioPhoneNumberE164,
    );
  }

  /// True if this facility has an active platform subscription (per-facility model)
  bool get hasActivePlatformSubscription =>
      platformSubscriptionStatus == 'active' ||
      platformSubscriptionStatus == 'trialing';

  // Calculate occupancy percentage
  double get occupancyPercentage {
    if (totalUnits == 0) return 0.0;
    return (occupiedUnits / totalUnits) * 100;
  }

  // Check if facility is full
  bool get isFull => occupiedUnits >= totalUnits;

  @override
  String toString() {
    return 'FacilityModel(id: $id, name: $name, ownerUid: $ownerUid, totalUnits: $totalUnits, occupiedUnits: $occupiedUnits, active: $active)';
  }
}
