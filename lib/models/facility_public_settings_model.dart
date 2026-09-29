import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:sfcapp/utils/firestore_field_read.dart';

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
  final String? publicLogoUrl; // Public-facing logo override
  final String? marketingContent; // Free-form public marketing content
  final Map<String, String>? unitTypeImageUrls; // Image URL per unit type slug
  final String? pageTitle; // Custom page title
  final String? pageDescription; // Page meta description
  final List<String>? featuredImages; // URLs to featured images
  final bool showAvailableUnits; // Show available units on page
  final bool allowOnlineReservations; // Allow online reservations
  final bool allowOnlineMoveIn; // Allow full online move-in
  final bool
      chargeNextMonthAfterMidMonthMoveIn; // If move-in is after mid-month, charge next month too
  final bool chargeInsuranceAtMoveIn; // Charge insurance at move-in
  final double? publicInsuranceAmount; // Insurance amount to charge at move-in
  final bool chargeSecurityDepositAtMoveIn; // Charge deposit at move-in
  final double?
      publicSecurityDepositAmount; // Deposit amount override for move-in
  /// When set, online move-in merges this [facilities/.../contractTemplates] PDF
  /// with the tenant e-sign certificate. Null uses the built-in summary PDF only.
  final String? onlineMoveInContractTemplateId;
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
    this.publicLogoUrl,
    this.marketingContent,
    this.unitTypeImageUrls,
    this.pageTitle,
    this.pageDescription,
    this.featuredImages,
    this.showAvailableUnits = true,
    this.allowOnlineReservations = true,
    this.allowOnlineMoveIn = false,
    this.chargeNextMonthAfterMidMonthMoveIn = false,
    this.chargeInsuranceAtMoveIn = false,
    this.publicInsuranceAmount,
    this.chargeSecurityDepositAtMoveIn = false,
    this.publicSecurityDepositAmount,
    this.onlineMoveInContractTemplateId,
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
      'publicLogoUrl': publicLogoUrl,
      'marketingContent': marketingContent,
      'unitTypeImageUrls': unitTypeImageUrls,
      'pageTitle': pageTitle,
      'pageDescription': pageDescription,
      'featuredImages': featuredImages,
      'showAvailableUnits': showAvailableUnits,
      'allowOnlineReservations': allowOnlineReservations,
      'allowOnlineMoveIn': allowOnlineMoveIn,
      'chargeNextMonthAfterMidMonthMoveIn': chargeNextMonthAfterMidMonthMoveIn,
      'chargeInsuranceAtMoveIn': chargeInsuranceAtMoveIn,
      'publicInsuranceAmount': publicInsuranceAmount,
      'chargeSecurityDepositAtMoveIn': chargeSecurityDepositAtMoveIn,
      'publicSecurityDepositAmount': publicSecurityDepositAmount,
      'onlineMoveInContractTemplateId': onlineMoveInContractTemplateId,
      'customStyles': customStyles,
      'widgets': widgets,
      'updatedAt': updatedAt != null ? Timestamp.fromDate(updatedAt!) : null,
      'updatedBy': updatedBy,
    };
  }

  /// Reads each field on its own and never throws on a value of the wrong
  /// type: a switch that is not a bool takes its default (as the server's
  /// `=== true` and `!== false` read it), a list keeps its strings, a map its
  /// string entries, and anything else reads as missing. This used casts, so
  /// one odd value (a number in enabledPublicUnitTypes, a null image URL, an
  /// updatedAt that was not a Timestamp) failed the whole read, and with
  /// saves refusing on a failed read the owner could not save at all.
  factory FacilityPublicSettings.fromMap(Map<String, dynamic> map) {
    bool flag(String key, bool fallback) {
      final value = map[key];
      return value is bool ? value : fallback;
    }

    String? text(String key) {
      final value = map[key];
      return value is String ? value : null;
    }

    List<String>? strings(String key) {
      final value = map[key];
      return value is List ? value.whereType<String>().toList() : null;
    }

    Map<String, dynamic>? object(String key) {
      final value = map[key];
      return value is Map
          ? {
              for (final e in value.entries)
                if (e.key is String) e.key as String: e.value,
            }
          : null;
    }

    final imageUrls = object('unitTypeImageUrls');
    return FacilityPublicSettings(
      facilityId: text('facilityId') ?? '',
      enabled: flag('enabled', false),
      publicRentalsEnabled: flag('publicRentalsEnabled', false),
      publicPricingEnabled: flag('publicPricingEnabled', true),
      publicUnitNumbersEnabled: flag('publicUnitNumbersEnabled', true),
      allowAutoAssign: flag('allowAutoAssign', true),
      allowUnitSelection: flag('allowUnitSelection', true),
      showAvailabilityCount: flag('showAvailabilityCount', true),
      hideUnavailableTypes: flag('hideUnavailableTypes', true),
      enabledPublicUnitTypes:
          strings('enabledPublicUnitTypes') ?? const <String>[],
      publicRentalSlug: text('publicRentalSlug'),
      customDomain: text('customDomain'),
      publicLogoUrl: text('publicLogoUrl'),
      marketingContent: text('marketingContent'),
      unitTypeImageUrls: imageUrls == null
          ? null
          : {
              for (final e in imageUrls.entries)
                if (e.value is String) e.key: e.value as String,
            },
      pageTitle: text('pageTitle'),
      pageDescription: text('pageDescription'),
      featuredImages: strings('featuredImages'),
      showAvailableUnits: flag('showAvailableUnits', true),
      allowOnlineReservations: flag('allowOnlineReservations', true),
      allowOnlineMoveIn: flag('allowOnlineMoveIn', false),
      chargeNextMonthAfterMidMonthMoveIn:
          flag('chargeNextMonthAfterMidMonthMoveIn', false),
      chargeInsuranceAtMoveIn: flag('chargeInsuranceAtMoveIn', false),
      // As the server's Number() reads a move-in charge: '12' is 12.
      publicInsuranceAmount: numberFromField(map['publicInsuranceAmount']),
      chargeSecurityDepositAtMoveIn:
          flag('chargeSecurityDepositAtMoveIn', false),
      publicSecurityDepositAmount:
          numberFromField(map['publicSecurityDepositAmount']),
      onlineMoveInContractTemplateId: text('onlineMoveInContractTemplateId'),
      customStyles: object('customStyles'),
      widgets: object('widgets'),
      updatedAt: dateFromField(map['updatedAt']),
      updatedBy: text('updatedBy'),
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
