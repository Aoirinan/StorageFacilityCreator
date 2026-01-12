import 'package:cloud_firestore/cloud_firestore.dart';

class FacilityModel {
  final String id;
  final String name;
  final String? logoUrl;
  final String ownerUid;
  final String? facilityCreatorAccountId; // Link to Facility Creator Account (for SaaS model)
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
  final Map<String, dynamic>? billingSettings; // Late fee rules, tax rate, grace period
  final Map<String, dynamic>? insuranceSettings; // TPP settings, auto-enrollment rules
  
  // Stripe Connect integration
  final String? stripeConnectAccountId; // Connected Stripe account ID
  final bool stripeConnectOnboardingComplete; // Whether onboarding is complete
  
  // Localization
  final String? defaultLocale; // Default language/locale for facility (e.g., "en_US", "es_ES")

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
    this.defaultLocale,
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
      businessHours: data?['businessHours'] != null ? Map<String, dynamic>.from(data!['businessHours']) : null,
      gateHours: data?['gateHours'] != null ? Map<String, dynamic>.from(data!['gateHours']) : null,
      billingSettings: data?['billingSettings'] != null ? Map<String, dynamic>.from(data!['billingSettings']) : null,
      insuranceSettings: data?['insuranceSettings'] != null ? Map<String, dynamic>.from(data!['insuranceSettings']) : null,
      stripeConnectAccountId: data?['stripeConnectAccountId'],
      stripeConnectOnboardingComplete: data?['stripeConnectOnboardingComplete'] ?? false,
      defaultLocale: data?['defaultLocale'] as String?,
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
      'updatedAt': updatedAt != null ? Timestamp.fromDate(updatedAt!) : FieldValue.serverTimestamp(),
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
      'defaultLocale': defaultLocale,
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
    String? defaultLocale,
  }) {
    return FacilityModel(
      id: id ?? this.id,
      name: name ?? this.name,
      logoUrl: logoUrl ?? this.logoUrl,
      ownerUid: ownerUid ?? this.ownerUid,
      facilityCreatorAccountId: facilityCreatorAccountId ?? this.facilityCreatorAccountId,
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
      stripeConnectAccountId: stripeConnectAccountId ?? this.stripeConnectAccountId,
      stripeConnectOnboardingComplete: stripeConnectOnboardingComplete ?? this.stripeConnectOnboardingComplete,
      defaultLocale: defaultLocale ?? this.defaultLocale,
    );
  }

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
