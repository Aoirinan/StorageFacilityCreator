import 'package:cloud_firestore/cloud_firestore.dart';
import 'occupant_model.dart';
import 'address_model.dart';
import 'tenant_autopay_model.dart';
import 'tenant_stripe_model.dart';

enum InsuranceStatus {
  none,
  pendingProof,
  providedProof,
  enrolledInTPP,
  autoEnrolled, // Auto-enrolled in TPP due to lack of proof
}

class TenantContact {
  final String name;
  final String? relationship;
  final String? phone;
  final String? email;
  final bool isPrimary;
  final bool isEmergency;

  const TenantContact({
    required this.name,
    this.relationship,
    this.phone,
    this.email,
    this.isPrimary = false,
    this.isEmergency = true,
  });

  factory TenantContact.fromMap(Map<String, dynamic> data) {
    return TenantContact(
      name: (data['name'] as String? ?? '').trim(),
      relationship: (data['relationship'] as String?)?.trim(),
      phone: (data['phone'] as String?)?.trim(),
      email: (data['email'] as String?)?.trim(),
      isPrimary: data['isPrimary'] ?? false,
      isEmergency: data['isEmergency'] ?? true,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      if (relationship != null && relationship!.isNotEmpty)
        'relationship': relationship,
      if (phone != null && phone!.isNotEmpty) 'phone': phone,
      if (email != null && email!.isNotEmpty) 'email': email,
      'isPrimary': isPrimary,
      'isEmergency': isEmergency,
    };
  }
}

class TenantVehicle {
  final String make;
  final String model;
  final String? color;
  final String? licensePlate;
  final String? state;
  final String? notes;

  const TenantVehicle({
    required this.make,
    required this.model,
    this.color,
    this.licensePlate,
    this.state,
    this.notes,
  });

  factory TenantVehicle.fromMap(Map<String, dynamic> data) {
    return TenantVehicle(
      make: (data['make'] as String? ?? '').trim(),
      model: (data['model'] as String? ?? '').trim(),
      color: (data['color'] as String?)?.trim(),
      licensePlate: (data['licensePlate'] as String?)?.trim(),
      state: (data['state'] as String?)?.trim(),
      notes: (data['notes'] as String?)?.trim(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'make': make,
      'model': model,
      if (color != null && color!.isNotEmpty) 'color': color,
      if (licensePlate != null && licensePlate!.isNotEmpty)
        'licensePlate': licensePlate,
      if (state != null && state!.isNotEmpty) 'state': state,
      if (notes != null && notes!.isNotEmpty) 'notes': notes,
    };
  }
}

class TenantModel {
  final String id;
  final String facilityId;
  final String name;
  final String email;
  final String phone;
  final String unitNumber;
  final double monthlyRate;
  final DateTime? paidThrough;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final bool isActive;
  final String? contractUrl;
  final String? notes;
  final bool isOnDNR;
  final String? governmentIdType;
  final String? governmentIdNumber;
  final String? governmentIdState;
  final String? governmentIdCountry;
  final DateTime? governmentIdIssuedAt;
  final DateTime? governmentIdExpiresAt;
  final List<TenantContact> emergencyContacts;
  final List<TenantVehicle> vehicles;
  final List<Occupant> occupants; // Authorized people/users on lease
  final List<Address> addresses; // Mailing + alternate addresses
  final bool portalEnabled;
  final String? portalAccessCode;
  final String? portalWelcomeMessage;
  final DateTime? portalLastAccessAt;
  final int portalVisitCount;
  // Insurance and delinquency fields
  final InsuranceStatus insuranceStatus;
  final String? insuranceProvider;
  final String? insuranceProofUrl;
  final double? coverageAmount;
  final DateTime? insuranceNotifiedDate;
  final DateTime? tppEnrollmentDate;
  final String? tppCoverageLevel;
  final String? delinquencyStatus;
  final DateTime? lastLateFeeDate;
  final DateTime? lienEligibleDate;
  final DateTime? lienFiledDate;
  final DateTime? auctionScheduledDate;
  final DateTime? auctionDate;
  final String?
      leadSource; // Where the tenant came from (e.g., "walkIn", "referral", "online")
  final String?
      preferredLocale; // Preferred language/locale (e.g., "en_US", "es_ES")

  // SMS Compliance fields (optional, backward compatible)
  final bool smsOptOut; // Tenant has opted out of SMS
  final DateTime? smsOptOutDate; // When tenant opted out
  final DateTime? smsOptInDate; // When tenant opted in
  final String? smsQuietHoursStart; // Quiet hours start time (HH:mm format)
  final String? smsQuietHoursEnd; // Quiet hours end time (HH:mm format)
  final int? smsRateLimitPerDay; // Daily SMS rate limit for this tenant
  final int smsMessagesSentToday; // Messages sent today (reset daily)
  final DateTime? smsLastResetDate; // Last time the daily counter was reset
  final String smsConsentStatus; // opted_in | opted_out | unknown
  final DateTime? smsConsentTimestamp;
  final String? smsConsentSource;

  // Autopay: OFF | REQUESTED | ON (synced facility + portal)
  final TenantAutopayModel autopay;
  // Stripe on connected account: customerId, defaultPaymentMethodId, safe display summary
  final TenantStripeModel stripe;

  /// Denormalized: true if this tenant's unit is currently overlocked (synced from unit.overlock).
  final bool overlockIsActive;

  /// Manual per-month status overrides: key "yyyy-MM", value "paid"|"late"|"moved_out".
  final Map<String, String> monthStatusOverrides;

  TenantModel({
    required this.id,
    required this.facilityId,
    required this.name,
    required this.email,
    required this.phone,
    required this.unitNumber,
    required this.monthlyRate,
    this.paidThrough,
    required this.createdAt,
    this.updatedAt,
    this.isActive = true,
    this.contractUrl,
    this.notes,
    this.isOnDNR = false,
    this.governmentIdType,
    this.governmentIdNumber,
    this.governmentIdState,
    this.governmentIdCountry,
    this.governmentIdIssuedAt,
    this.governmentIdExpiresAt,
    this.emergencyContacts = const [],
    this.vehicles = const [],
    this.occupants = const [],
    this.addresses = const [],
    this.portalEnabled = false,
    this.portalAccessCode,
    this.portalWelcomeMessage,
    this.portalLastAccessAt,
    this.portalVisitCount = 0,
    this.insuranceStatus = InsuranceStatus.none,
    this.insuranceProvider,
    this.insuranceProofUrl,
    this.coverageAmount,
    this.insuranceNotifiedDate,
    this.tppEnrollmentDate,
    this.tppCoverageLevel,
    this.delinquencyStatus,
    this.lastLateFeeDate,
    this.lienEligibleDate,
    this.lienFiledDate,
    this.auctionScheduledDate,
    this.auctionDate,
    this.leadSource,
    this.preferredLocale,
    this.smsOptOut = false,
    this.smsOptOutDate,
    this.smsOptInDate,
    this.smsQuietHoursStart,
    this.smsQuietHoursEnd,
    this.smsRateLimitPerDay,
    this.smsMessagesSentToday = 0,
    this.smsLastResetDate,
    this.smsConsentStatus = 'unknown',
    this.smsConsentTimestamp,
    this.smsConsentSource,
    this.autopay = const TenantAutopayModel(),
    this.stripe = const TenantStripeModel(),
    this.overlockIsActive = false,
    this.monthStatusOverrides = const {},
  });

  // Create TenantModel from Firestore document
  factory TenantModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;

    return TenantModel(
      id: doc.id,
      facilityId: data?['facilityId'] ?? '',
      name: data?['name'] ?? '',
      email: data?['email'] ?? '',
      phone: data?['phone'] ?? '',
      unitNumber: data?['unitNumber'] ?? '',
      monthlyRate: (data?['monthlyRate'] ?? 0.0).toDouble(),
      paidThrough: (data?['paidThrough'] as Timestamp?)?.toDate(),
      createdAt: (data?['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data?['updatedAt'] as Timestamp?)?.toDate(),
      isActive: data?['isActive'] ?? true,
      contractUrl: data?['contractUrl'],
      notes: data?['notes'],
      isOnDNR: data?['isOnDNR'] ?? false,
      governmentIdType: data?['governmentIdType'],
      governmentIdNumber: data?['governmentIdNumber'],
      governmentIdState: data?['governmentIdState'],
      governmentIdCountry: data?['governmentIdCountry'],
      governmentIdIssuedAt:
          (data?['governmentIdIssuedAt'] as Timestamp?)?.toDate(),
      governmentIdExpiresAt:
          (data?['governmentIdExpiresAt'] as Timestamp?)?.toDate(),
      emergencyContacts: (data?['emergencyContacts'] as List<dynamic>? ?? [])
          .map((item) => TenantContact.fromMap(
              Map<String, dynamic>.from(item as Map<dynamic, dynamic>)))
          .where((contact) =>
              contact.name.isNotEmpty ||
              (contact.phone != null && contact.phone!.isNotEmpty))
          .toList(),
      vehicles: (data?['vehicles'] as List<dynamic>? ?? [])
          .map((item) => TenantVehicle.fromMap(
              Map<String, dynamic>.from(item as Map<dynamic, dynamic>)))
          .where(
              (vehicle) => vehicle.make.isNotEmpty || vehicle.model.isNotEmpty)
          .toList(),
      occupants: (data?['occupants'] as List<dynamic>? ?? [])
          .map((item) => Occupant.fromMap(
              Map<String, dynamic>.from(item as Map<dynamic, dynamic>)))
          .where((occupant) => occupant.name.isNotEmpty)
          .toList(),
      addresses: (data?['addresses'] as List<dynamic>? ?? [])
          .map((item) => Address.fromMap(
              Map<String, dynamic>.from(item as Map<dynamic, dynamic>)))
          .where((address) => address.street1.isNotEmpty)
          .toList(),
      portalEnabled: data?['portalEnabled'] ?? false,
      portalAccessCode: data?['portalAccessCode'],
      portalWelcomeMessage: data?['portalWelcomeMessage'],
      portalLastAccessAt: (data?['portalLastAccessAt'] as Timestamp?)?.toDate(),
      portalVisitCount: ((data?['portalVisitCount'] ?? 0) as num).toInt(),
      insuranceStatus: _parseInsuranceStatus(data?['insuranceStatus']),
      insuranceProvider: data?['insuranceProvider'],
      insuranceProofUrl: data?['insuranceProofUrl'] as String?,
      coverageAmount: (data?['coverageAmount'] as num?)?.toDouble(),
      insuranceNotifiedDate:
          (data?['insuranceNotifiedDate'] as Timestamp?)?.toDate(),
      tppEnrollmentDate: (data?['tppEnrollmentDate'] as Timestamp?)?.toDate(),
      tppCoverageLevel: data?['tppCoverageLevel'],
      delinquencyStatus: data?['delinquencyStatus'],
      lastLateFeeDate: (data?['lastLateFeeDate'] as Timestamp?)?.toDate(),
      lienEligibleDate: (data?['lienEligibleDate'] as Timestamp?)?.toDate(),
      lienFiledDate: (data?['lienFiledDate'] as Timestamp?)?.toDate(),
      auctionScheduledDate:
          (data?['auctionScheduledDate'] as Timestamp?)?.toDate(),
      auctionDate: (data?['auctionDate'] as Timestamp?)?.toDate(),
      leadSource: data?['leadSource'] as String?,
      preferredLocale: data?['preferredLocale'] as String?,
      smsOptOut: data?['smsOptOut'] ?? false,
      smsOptOutDate: (data?['smsOptOutDate'] as Timestamp?)?.toDate(),
      smsOptInDate: (data?['smsOptInDate'] as Timestamp?)?.toDate(),
      smsQuietHoursStart: data?['smsQuietHoursStart'] as String?,
      smsQuietHoursEnd: data?['smsQuietHoursEnd'] as String?,
      smsRateLimitPerDay: (data?['smsRateLimitPerDay'] as num?)?.toInt(),
      smsMessagesSentToday:
          ((data?['smsMessagesSentToday'] ?? 0) as num).toInt(),
      smsLastResetDate: (data?['smsLastResetDate'] as Timestamp?)?.toDate(),
      smsConsentStatus: (data?['smsConsentStatus'] as String?) ?? 'unknown',
      smsConsentTimestamp:
          (data?['smsConsentTimestamp'] as Timestamp?)?.toDate(),
      smsConsentSource: data?['smsConsentSource'] as String?,
      autopay: data?['autopay'] != null
          ? TenantAutopayModel.fromMap(
              Map<String, dynamic>.from(data!['autopay'] as Map))
          : const TenantAutopayModel(),
      stripe: data?['stripe'] != null
          ? TenantStripeModel.fromMap(
              Map<String, dynamic>.from(data!['stripe'] as Map))
          : const TenantStripeModel(),
      overlockIsActive: data?['overlockIsActive'] == true,
      monthStatusOverrides: data?['monthStatusOverrides'] != null
          ? Map<String, String>.from((data!['monthStatusOverrides'] as Map)
              .map((k, v) => MapEntry(k.toString(), v.toString())))
          : {},
    );
  }

  static InsuranceStatus _parseInsuranceStatus(dynamic value) {
    if (value == null) return InsuranceStatus.none;
    if (value is String) {
      switch (value) {
        case 'none':
          return InsuranceStatus.none;
        case 'pendingProof':
          return InsuranceStatus.pendingProof;
        case 'providedProof':
          return InsuranceStatus.providedProof;
        case 'enrolledInTPP':
          return InsuranceStatus.enrolledInTPP;
        case 'autoEnrolled':
          return InsuranceStatus.autoEnrolled;
        default:
          return InsuranceStatus.none;
      }
    }
    return InsuranceStatus.none;
  }

  // Convert TenantModel to Map for Firestore
  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId,
      'name': name,
      'email': email,
      'phone': phone,
      'unitNumber': unitNumber,
      'monthlyRate': monthlyRate,
      'paidThrough':
          paidThrough != null ? Timestamp.fromDate(paidThrough!) : null,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': updatedAt != null
          ? Timestamp.fromDate(updatedAt!)
          : FieldValue.serverTimestamp(),
      'isActive': isActive,
      'contractUrl': contractUrl,
      'notes': notes,
      'isOnDNR': isOnDNR,
      if (governmentIdType != null && governmentIdType!.isNotEmpty)
        'governmentIdType': governmentIdType,
      if (governmentIdNumber != null && governmentIdNumber!.isNotEmpty)
        'governmentIdNumber': governmentIdNumber,
      if (governmentIdState != null && governmentIdState!.isNotEmpty)
        'governmentIdState': governmentIdState,
      if (governmentIdCountry != null && governmentIdCountry!.isNotEmpty)
        'governmentIdCountry': governmentIdCountry,
      if (governmentIdIssuedAt != null)
        'governmentIdIssuedAt': Timestamp.fromDate(governmentIdIssuedAt!),
      if (governmentIdExpiresAt != null)
        'governmentIdExpiresAt': Timestamp.fromDate(governmentIdExpiresAt!),
      'emergencyContacts':
          emergencyContacts.map((contact) => contact.toMap()).toList(),
      'vehicles': vehicles.map((vehicle) => vehicle.toMap()).toList(),
      'occupants': occupants.map((occupant) => occupant.toMap()).toList(),
      'addresses': addresses.map((address) => address.toMap()).toList(),
      'portalEnabled': portalEnabled,
      'portalAccessCode': portalAccessCode,
      'portalWelcomeMessage': portalWelcomeMessage,
      'portalLastAccessAt': portalLastAccessAt != null
          ? Timestamp.fromDate(portalLastAccessAt!)
          : null,
      'portalVisitCount': portalVisitCount,
      'insuranceStatus': insuranceStatus.name,
      if (insuranceProvider != null && insuranceProvider!.isNotEmpty)
        'insuranceProvider': insuranceProvider,
      if (insuranceProofUrl != null && insuranceProofUrl!.isNotEmpty)
        'insuranceProofUrl': insuranceProofUrl,
      if (coverageAmount != null) 'coverageAmount': coverageAmount,
      if (insuranceNotifiedDate != null)
        'insuranceNotifiedDate': Timestamp.fromDate(insuranceNotifiedDate!),
      if (tppEnrollmentDate != null)
        'tppEnrollmentDate': Timestamp.fromDate(tppEnrollmentDate!),
      if (tppCoverageLevel != null && tppCoverageLevel!.isNotEmpty)
        'tppCoverageLevel': tppCoverageLevel,
      if (delinquencyStatus != null && delinquencyStatus!.isNotEmpty)
        'delinquencyStatus': delinquencyStatus,
      if (lastLateFeeDate != null)
        'lastLateFeeDate': Timestamp.fromDate(lastLateFeeDate!),
      if (lienEligibleDate != null)
        'lienEligibleDate': Timestamp.fromDate(lienEligibleDate!),
      if (lienFiledDate != null)
        'lienFiledDate': Timestamp.fromDate(lienFiledDate!),
      if (auctionScheduledDate != null)
        'auctionScheduledDate': Timestamp.fromDate(auctionScheduledDate!),
      if (auctionDate != null) 'auctionDate': Timestamp.fromDate(auctionDate!),
      if (leadSource != null && leadSource!.isNotEmpty)
        'leadSource': leadSource,
      if (preferredLocale != null && preferredLocale!.isNotEmpty)
        'preferredLocale': preferredLocale,
      'smsOptOut': smsOptOut,
      if (smsOptOutDate != null)
        'smsOptOutDate': Timestamp.fromDate(smsOptOutDate!),
      if (smsOptInDate != null)
        'smsOptInDate': Timestamp.fromDate(smsOptInDate!),
      if (smsQuietHoursStart != null && smsQuietHoursStart!.isNotEmpty)
        'smsQuietHoursStart': smsQuietHoursStart,
      if (smsQuietHoursEnd != null && smsQuietHoursEnd!.isNotEmpty)
        'smsQuietHoursEnd': smsQuietHoursEnd,
      if (smsRateLimitPerDay != null) 'smsRateLimitPerDay': smsRateLimitPerDay,
      'smsMessagesSentToday': smsMessagesSentToday,
      if (smsLastResetDate != null)
        'smsLastResetDate': Timestamp.fromDate(smsLastResetDate!),
      'smsConsentStatus': smsConsentStatus,
      if (smsConsentTimestamp != null)
        'smsConsentTimestamp': Timestamp.fromDate(smsConsentTimestamp!),
      if (smsConsentSource != null && smsConsentSource!.isNotEmpty)
        'smsConsentSource': smsConsentSource,
      'autopay': autopay.toMap(),
      if (stripe.customerId != null || stripe.defaultPaymentMethodId != null)
        'stripe': stripe.toMap(),
      'overlockIsActive': overlockIsActive,
      if (monthStatusOverrides.isNotEmpty)
        'monthStatusOverrides': monthStatusOverrides,
    };
  }

  // Copy with method for updates
  TenantModel copyWith({
    String? id,
    String? facilityId,
    String? name,
    String? email,
    String? phone,
    String? unitNumber,
    double? monthlyRate,
    DateTime? paidThrough,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isActive,
    String? contractUrl,
    String? notes,
    bool? isOnDNR,
    String? governmentIdType,
    String? governmentIdNumber,
    String? governmentIdState,
    String? governmentIdCountry,
    DateTime? governmentIdIssuedAt,
    DateTime? governmentIdExpiresAt,
    List<TenantContact>? emergencyContacts,
    List<TenantVehicle>? vehicles,
    List<Occupant>? occupants,
    List<Address>? addresses,
    bool? portalEnabled,
    String? portalAccessCode,
    String? portalWelcomeMessage,
    DateTime? portalLastAccessAt,
    int? portalVisitCount,
    InsuranceStatus? insuranceStatus,
    String? insuranceProvider,
    String? insuranceProofUrl,
    double? coverageAmount,
    DateTime? insuranceNotifiedDate,
    DateTime? tppEnrollmentDate,
    String? tppCoverageLevel,
    String? delinquencyStatus,
    DateTime? lastLateFeeDate,
    DateTime? lienEligibleDate,
    DateTime? lienFiledDate,
    DateTime? auctionScheduledDate,
    DateTime? auctionDate,
    String? leadSource,
    String? preferredLocale,
    bool? smsOptOut,
    DateTime? smsOptOutDate,
    DateTime? smsOptInDate,
    String? smsQuietHoursStart,
    String? smsQuietHoursEnd,
    int? smsRateLimitPerDay,
    int? smsMessagesSentToday,
    DateTime? smsLastResetDate,
    String? smsConsentStatus,
    DateTime? smsConsentTimestamp,
    String? smsConsentSource,
    TenantAutopayModel? autopay,
    TenantStripeModel? stripe,
    bool? overlockIsActive,
    Map<String, String>? monthStatusOverrides,
  }) {
    return TenantModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      name: name ?? this.name,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      unitNumber: unitNumber ?? this.unitNumber,
      monthlyRate: monthlyRate ?? this.monthlyRate,
      paidThrough: paidThrough ?? this.paidThrough,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isActive: isActive ?? this.isActive,
      contractUrl: contractUrl ?? this.contractUrl,
      notes: notes ?? this.notes,
      isOnDNR: isOnDNR ?? this.isOnDNR,
      governmentIdType: governmentIdType ?? this.governmentIdType,
      governmentIdNumber: governmentIdNumber ?? this.governmentIdNumber,
      governmentIdState: governmentIdState ?? this.governmentIdState,
      governmentIdCountry: governmentIdCountry ?? this.governmentIdCountry,
      governmentIdIssuedAt: governmentIdIssuedAt ?? this.governmentIdIssuedAt,
      governmentIdExpiresAt:
          governmentIdExpiresAt ?? this.governmentIdExpiresAt,
      emergencyContacts: emergencyContacts ?? this.emergencyContacts,
      vehicles: vehicles ?? this.vehicles,
      occupants: occupants ?? this.occupants,
      addresses: addresses ?? this.addresses,
      portalEnabled: portalEnabled ?? this.portalEnabled,
      portalAccessCode: portalAccessCode ?? this.portalAccessCode,
      portalWelcomeMessage: portalWelcomeMessage ?? this.portalWelcomeMessage,
      portalLastAccessAt: portalLastAccessAt ?? this.portalLastAccessAt,
      portalVisitCount: portalVisitCount ?? this.portalVisitCount,
      insuranceStatus: insuranceStatus ?? this.insuranceStatus,
      insuranceProvider: insuranceProvider ?? this.insuranceProvider,
      insuranceProofUrl: insuranceProofUrl ?? this.insuranceProofUrl,
      coverageAmount: coverageAmount ?? this.coverageAmount,
      insuranceNotifiedDate:
          insuranceNotifiedDate ?? this.insuranceNotifiedDate,
      tppEnrollmentDate: tppEnrollmentDate ?? this.tppEnrollmentDate,
      tppCoverageLevel: tppCoverageLevel ?? this.tppCoverageLevel,
      delinquencyStatus: delinquencyStatus ?? this.delinquencyStatus,
      lastLateFeeDate: lastLateFeeDate ?? this.lastLateFeeDate,
      lienEligibleDate: lienEligibleDate ?? this.lienEligibleDate,
      lienFiledDate: lienFiledDate ?? this.lienFiledDate,
      auctionScheduledDate: auctionScheduledDate ?? this.auctionScheduledDate,
      auctionDate: auctionDate ?? this.auctionDate,
      leadSource: leadSource ?? this.leadSource,
      preferredLocale: preferredLocale ?? this.preferredLocale,
      smsOptOut: smsOptOut ?? this.smsOptOut,
      smsOptOutDate: smsOptOutDate ?? this.smsOptOutDate,
      smsOptInDate: smsOptInDate ?? this.smsOptInDate,
      smsQuietHoursStart: smsQuietHoursStart ?? this.smsQuietHoursStart,
      smsQuietHoursEnd: smsQuietHoursEnd ?? this.smsQuietHoursEnd,
      smsRateLimitPerDay: smsRateLimitPerDay ?? this.smsRateLimitPerDay,
      smsMessagesSentToday: smsMessagesSentToday ?? this.smsMessagesSentToday,
      smsLastResetDate: smsLastResetDate ?? this.smsLastResetDate,
      smsConsentStatus: smsConsentStatus ?? this.smsConsentStatus,
      smsConsentTimestamp: smsConsentTimestamp ?? this.smsConsentTimestamp,
      smsConsentSource: smsConsentSource ?? this.smsConsentSource,
      autopay: autopay ?? this.autopay,
      stripe: stripe ?? this.stripe,
      overlockIsActive: overlockIsActive ?? this.overlockIsActive,
      monthStatusOverrides: monthStatusOverrides ?? this.monthStatusOverrides,
    );
  }

  // Get normalized phone number (digits only)
  String get phoneDigits {
    return phone.replaceAll(RegExp(r'[^\d]'), '');
  }

  // Get normalized name (lowercase)
  String get nameLower {
    return name.toLowerCase();
  }

  // Get normalized email (lowercase)
  String get emailLower {
    return email.toLowerCase();
  }

  // Check if tenant is late on payments
  bool get isLate {
    const gracePeriodDays = 3;
    final now = DateTime.now();
    final startOfCurrentMonth = DateTime(now.year, now.month, 1);
    final paidThroughDate = paidThrough;

    // If tenant has never paid, check if they're a new tenant
    if (paidThroughDate == null) {
      // If tenant was created in the current month, they're not late yet
      // Use a more lenient check - if created within the last 30 days, don't mark as late
      final daysSinceCreation = now.difference(createdAt).inDays;
      final tenantCreatedRecently = daysSinceCreation <= 30;

      if (tenantCreatedRecently) {
        // New tenant created within last 30 days - not late yet
        return false;
      }

      // Also check if created this month (backup check)
      final tenantCreatedThisMonth =
          createdAt.year == now.year && createdAt.month == now.month;
      if (tenantCreatedThisMonth) {
        return false;
      }

      // Tenant created more than 30 days ago with no payment - they are late
      return true;
    }

    // Tenant has paid - check if payment is still valid
    final graceBoundary =
        startOfCurrentMonth.subtract(const Duration(days: gracePeriodDays));
    return paidThroughDate.isBefore(graceBoundary);
  }

  // Get days late (0 if not late)
  int get daysLate {
    if (!isLate) return 0;

    const gracePeriodDays = 3;
    final now = DateTime.now();
    final startOfCurrentMonth = DateTime(now.year, now.month, 1);
    final paidThroughDate = paidThrough;

    // If never paid, calculate from creation date or start of month
    final referenceDate = paidThroughDate ??
        (createdAt.year == now.year && createdAt.month == now.month
            ? createdAt // Use creation date if created this month
            : startOfCurrentMonth); // Otherwise use start of month

    final difference =
        startOfCurrentMonth.difference(referenceDate).inDays - gracePeriodDays;

    return difference < 0 ? 0 : difference;
  }

  // Get next due date
  DateTime get nextDueDate {
    if (paidThrough == null) {
      // If never paid, due date is start of current month
      final now = DateTime.now();
      return DateTime(now.year, now.month, 1);
    }

    // Next due date is first day of the month after paidThrough
    final paidThroughMonth = paidThrough!.month;
    final paidThroughYear = paidThrough!.year;

    if (paidThroughMonth == 12) {
      return DateTime(paidThroughYear + 1, 1, 1);
    } else {
      return DateTime(paidThroughYear, paidThroughMonth + 1, 1);
    }
  }

  @override
  String toString() {
    return 'TenantModel(id: $id, name: $name, facilityId: $facilityId, unitNumber: $unitNumber, monthlyRate: $monthlyRate)';
  }
}

// Extension for InsuranceStatus display names
extension InsuranceStatusExtension on InsuranceStatus {
  String get displayName {
    switch (this) {
      case InsuranceStatus.none:
        return 'No Insurance';
      case InsuranceStatus.pendingProof:
        return 'Proof Pending';
      case InsuranceStatus.providedProof:
        return 'Proof Provided';
      case InsuranceStatus.enrolledInTPP:
        return 'Enrolled in TPP';
      case InsuranceStatus.autoEnrolled:
        return 'Auto-Enrolled in TPP';
    }
  }
}
