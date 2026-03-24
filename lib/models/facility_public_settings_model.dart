import 'package:cloud_firestore/cloud_firestore.dart';

/// Public facility page settings
class FacilityPublicSettings {
  final String facilityId;
  final bool enabled; // Whether public page is enabled
  final bool publicRentalsEnabled; // Whether online public rentals are enabled
  final bool publicPricingEnabled; // Show pricing on public rental pages
  final bool publicUnitNumbersEnabled; // Show exact unit numbers publicly
  final bool allowAutoAssign; // Allow automatic unit assignment
  final bool allowUnitSelection; // Allow renter to choose specific unit
  final bool showAvailabilityCount; // Show "X available" counts
  final bool
      hideUnavailableTypes; // Hide categories/types that have zero inventory
  final List<String> enabledPublicUnitTypes; // Publicly rentable unit types
  final String? publicRentalSlug; // Public rental slug used in /f/:slug/*
  final String? customDomain; // Custom domain for facility page
  final String? pageTitle; // Custom page title
  final String? pageDescription; // Page meta description
  final List<String>? featuredImages; // URLs to featured images
  final bool showAvailableUnits; // Show available units on page
  final bool allowOnlineReservations; // Allow online reservations
  final bool allowOnlineMoveIn; // Allow full online move-in
  final Map<String, dynamic>? customStyles; // Custom CSS/styling
  final Map<String, dynamic>? widgets; // Widget configuration
  final DateTime? updatedAt;
  final String? updatedBy;

  const FacilityPublicSettings({
    required this.facilityId,
    this.enabled = false,
    this.publicRentalsEnabled = false,
    this.publicPricingEnabled = true,
    this.publicUnitNumbersEnabled = true,
    this.allowAutoAssign = true,
    this.allowUnitSelection = true,
    this.showAvailabilityCount = true,
    this.hideUnavailableTypes = true,
    this.enabledPublicUnitTypes = const <String>[],
    this.publicRentalSlug,
    this.customDomain,
    this.pageTitle,
    this.pageDescription,
    this.featuredImages,
    this.showAvailableUnits = true,
    this.allowOnlineReservations = true,
    this.allowOnlineMoveIn = false,
    this.customStyles,
    this.widgets,
    this.updatedAt,
    this.updatedBy,
  });

  Map<String, dynamic> toMap() {
    return {
      'facilityId': facilityId,
      'enabled': enabled,
      'publicRentalsEnabled': publicRentalsEnabled,
      'publicPricingEnabled': publicPricingEnabled,
      'publicUnitNumbersEnabled': publicUnitNumbersEnabled,
      'allowAutoAssign': allowAutoAssign,
      'allowUnitSelection': allowUnitSelection,
      'showAvailabilityCount': showAvailabilityCount,
      'hideUnavailableTypes': hideUnavailableTypes,
      'enabledPublicUnitTypes': enabledPublicUnitTypes,
      'publicRentalSlug': publicRentalSlug,
      'customDomain': customDomain,
      'pageTitle': pageTitle,
      'pageDescription': pageDescription,
      'featuredImages': featuredImages,
      'showAvailableUnits': showAvailableUnits,
      'allowOnlineReservations': allowOnlineReservations,
      'allowOnlineMoveIn': allowOnlineMoveIn,
      'customStyles': customStyles,
      'widgets': widgets,
      'updatedAt': updatedAt != null ? Timestamp.fromDate(updatedAt!) : null,
      'updatedBy': updatedBy,
    };
  }

  factory FacilityPublicSettings.fromMap(Map<String, dynamic> map) {
    return FacilityPublicSettings(
      facilityId: map['facilityId'] as String,
      enabled: map['enabled'] as bool? ?? false,
      publicRentalsEnabled: map['publicRentalsEnabled'] as bool? ?? false,
      publicPricingEnabled: map['publicPricingEnabled'] as bool? ?? true,
      publicUnitNumbersEnabled:
          map['publicUnitNumbersEnabled'] as bool? ?? true,
      allowAutoAssign: map['allowAutoAssign'] as bool? ?? true,
      allowUnitSelection: map['allowUnitSelection'] as bool? ?? true,
      showAvailabilityCount: map['showAvailabilityCount'] as bool? ?? true,
      hideUnavailableTypes: map['hideUnavailableTypes'] as bool? ?? true,
      enabledPublicUnitTypes: map['enabledPublicUnitTypes'] != null
          ? List<String>.from(map['enabledPublicUnitTypes'])
          : const <String>[],
      publicRentalSlug: map['publicRentalSlug'] as String?,
      customDomain: map['customDomain'] as String?,
      pageTitle: map['pageTitle'] as String?,
      pageDescription: map['pageDescription'] as String?,
      featuredImages: map['featuredImages'] != null
          ? List<String>.from(map['featuredImages'])
          : null,
      showAvailableUnits: map['showAvailableUnits'] as bool? ?? true,
      allowOnlineReservations: map['allowOnlineReservations'] as bool? ?? true,
      allowOnlineMoveIn: map['allowOnlineMoveIn'] as bool? ?? false,
      customStyles: map['customStyles'] as Map<String, dynamic>?,
      widgets: map['widgets'] as Map<String, dynamic>?,
      updatedAt: (map['updatedAt'] as Timestamp?)?.toDate(),
      updatedBy: map['updatedBy'] as String?,
    );
  }
}

/// Widget configuration for embeddable widgets
enum WidgetType {
  unitAvailability,
  reservation,
  payment,
  contactForm,
}

class WidgetConfig {
  final WidgetType type;
  final Map<String, dynamic>? settings;
  final bool enabled;
  final String? customCss;

  const WidgetConfig({
    required this.type,
    this.settings,
    this.enabled = true,
    this.customCss,
  });

  Map<String, dynamic> toMap() {
    return {
      'type': type.name,
      'settings': settings,
      'enabled': enabled,
      'customCss': customCss,
    };
  }

  factory WidgetConfig.fromMap(Map<String, dynamic> map) {
    return WidgetConfig(
      type: WidgetType.values.firstWhere(
        (t) => t.name == map['type'],
        orElse: () => WidgetType.unitAvailability,
      ),
      settings: map['settings'] as Map<String, dynamic>?,
      enabled: map['enabled'] as bool? ?? true,
      customCss: map['customCss'] as String?,
    );
  }
}
