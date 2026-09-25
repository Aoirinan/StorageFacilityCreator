import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/facility_public_settings_model.dart';
import '../models/facility_model.dart';
import '../utils/renter_account_message.dart' show normalizeCustomDomain;
import 'package:sfcapp/utils/error_message_helper.dart';

/// A save refused because the facility's saved public settings could not be
/// read. [FacilityPublicService.updatePublicSettings] keeps every field it is
/// not given from them; when the read failed (offline, a transient error,
/// permission) it used to fall back to defaults and write those, so a Website
/// Setup save cleared the contract template, the unit types, the custom
/// domain, the logo and the move-in charges.
class PublicSettingsNotReadException implements UserFacingException {
  const PublicSettingsNotReadException(this.cause);

  final Object cause;

  @override
  String get message =>
      "This facility's saved website and rental settings could not be "
      'loaded, so nothing was saved. Check your connection and try again.';

  @override
  String toString() => message;
}

/// Service for managing public facility pages and widgets
class FacilityPublicService {
  // Getters, not final fields, so tests can run the real settings writes
  // against a fake Firestore and a signed-in fake user.
  static FirebaseFirestore get _firestore =>
      _firestoreForTesting ?? FirebaseFirestore.instance;
  static FirebaseFirestore? _firestoreForTesting;
  static FirebaseAuth get _auth => _authForTesting ?? FirebaseAuth.instance;
  static FirebaseAuth? _authForTesting;

  @visibleForTesting
  static set firestoreForTesting(FirebaseFirestore? firestore) =>
      _firestoreForTesting = firestore;

  @visibleForTesting
  static set authForTesting(FirebaseAuth? auth) => _authForTesting = auth;

  /// The facility's public settings, or the defaults when it has none yet.
  /// Throws when they cannot be read, so a caller that writes what it read
  /// cannot mistake a failed read for a facility with default settings.
  static Future<FacilityPublicSettings> getPublicSettingsOrThrow(
      String facilityId) async {
    final doc = await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('settings')
        .doc('public')
        .get();
    final data = doc.data();
    if (!doc.exists || data == null) {
      return FacilityPublicSettings(facilityId: facilityId);
    }
    // The path names the facility. The website-subscription webhook and the
    // custom-domain sync create this doc with a merge that has no facilityId,
    // and fromMap needs one, so reading those facilities' settings failed.
    return FacilityPublicSettings.fromMap({...data, 'facilityId': facilityId});
  }

  /// Get public settings for a facility, or null when they cannot be read.
  /// For display only: anything that writes what it read uses
  /// [getPublicSettingsOrThrow].
  static Future<FacilityPublicSettings?> getPublicSettings(
      String facilityId) async {
    try {
      return await getPublicSettingsOrThrow(facilityId);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [FacilityPublic] Error getting public settings: $e');
      }
      return null;
    }
  }

  /// Update public settings for a facility
  static Future<void> updatePublicSettings({
    required String facilityId,
    bool? enabled,
    bool? publicRentalsEnabled,
    bool? publicPricingEnabled,
    bool? publicUnitNumbersEnabled,
    bool? allowAutoAssign,
    bool? allowUnitSelection,
    bool? showAvailabilityCount,
    bool? hideUnavailableTypes,
    List<String>? enabledPublicUnitTypes,
    String? publicRentalSlug,
    String? customDomain,
    String? publicLogoUrl,
    String? marketingContent,
    Map<String, String>? unitTypeImageUrls,
    String? pageTitle,
    String? pageDescription,
    List<String>? featuredImages,
    bool? showAvailableUnits,
    bool? allowOnlineReservations,
    bool? allowOnlineMoveIn,
    bool? chargeNextMonthAfterMidMonthMoveIn,
    bool? chargeInsuranceAtMoveIn,
    double? publicInsuranceAmount,
    bool? chargeSecurityDepositAtMoveIn,
    double? publicSecurityDepositAmount,
    String? onlineMoveInContractTemplateId,
    /// When true, [onlineMoveInContractTemplateId] replaces the stored value (including null to clear).
    bool replaceOnlineMoveInContractTemplate = false,
    Map<String, dynamic>? customStyles,
    Map<String, dynamic>? widgets,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      // Every field not given below is kept from these, and the whole doc is
      // written. Without them there is nothing to keep, so write nothing.
      final FacilityPublicSettings currentSettings;
      try {
        currentSettings = await getPublicSettingsOrThrow(facilityId);
      } catch (e) {
        throw PublicSettingsNotReadException(e);
      }
      final updatedSettings = FacilityPublicSettings(
        facilityId: facilityId,
        enabled: enabled ?? currentSettings.enabled,
        publicRentalsEnabled:
            publicRentalsEnabled ?? currentSettings.publicRentalsEnabled,
        publicPricingEnabled:
            publicPricingEnabled ?? currentSettings.publicPricingEnabled,
        publicUnitNumbersEnabled: publicUnitNumbersEnabled ??
            currentSettings.publicUnitNumbersEnabled,
        allowAutoAssign: allowAutoAssign ?? currentSettings.allowAutoAssign,
        allowUnitSelection:
            allowUnitSelection ?? currentSettings.allowUnitSelection,
        showAvailabilityCount:
            showAvailabilityCount ?? currentSettings.showAvailabilityCount,
        hideUnavailableTypes:
            hideUnavailableTypes ?? currentSettings.hideUnavailableTypes,
        enabledPublicUnitTypes:
            enabledPublicUnitTypes ?? currentSettings.enabledPublicUnitTypes,
        publicRentalSlug: publicRentalSlug ?? currentSettings.publicRentalSlug,
        customDomain: customDomain ?? currentSettings.customDomain,
        publicLogoUrl: publicLogoUrl ?? currentSettings.publicLogoUrl,
        marketingContent: marketingContent ?? currentSettings.marketingContent,
        unitTypeImageUrls:
            unitTypeImageUrls ?? currentSettings.unitTypeImageUrls,
        pageTitle: pageTitle ?? currentSettings.pageTitle,
        pageDescription: pageDescription ?? currentSettings.pageDescription,
        featuredImages: featuredImages ?? currentSettings.featuredImages,
        showAvailableUnits:
            showAvailableUnits ?? currentSettings.showAvailableUnits,
        allowOnlineReservations:
            allowOnlineReservations ?? currentSettings.allowOnlineReservations,
        allowOnlineMoveIn: allowOnlineMoveIn ?? currentSettings.allowOnlineMoveIn,
        chargeNextMonthAfterMidMonthMoveIn:
            chargeNextMonthAfterMidMonthMoveIn ??
                currentSettings.chargeNextMonthAfterMidMonthMoveIn,
        chargeInsuranceAtMoveIn:
            chargeInsuranceAtMoveIn ?? currentSettings.chargeInsuranceAtMoveIn,
        publicInsuranceAmount:
            publicInsuranceAmount ?? currentSettings.publicInsuranceAmount,
        chargeSecurityDepositAtMoveIn: chargeSecurityDepositAtMoveIn ??
            currentSettings.chargeSecurityDepositAtMoveIn,
        publicSecurityDepositAmount: publicSecurityDepositAmount ??
            currentSettings.publicSecurityDepositAmount,
        onlineMoveInContractTemplateId: replaceOnlineMoveInContractTemplate
            ? (onlineMoveInContractTemplateId != null &&
                    onlineMoveInContractTemplateId.trim().isNotEmpty
                ? onlineMoveInContractTemplateId.trim()
                : null)
            : currentSettings.onlineMoveInContractTemplateId,
        customStyles: customStyles ?? currentSettings.customStyles,
        widgets: widgets ?? currentSettings.widgets,
        updatedAt: DateTime.now(),
        updatedBy: user.uid,
      );

      final normalizedNewDomain =
          customDomain != null ? normalizeCustomDomain(customDomain) : null;
      final normalizedOldDomain =
          normalizeCustomDomain(currentSettings.customDomain ?? '');

      if (normalizedNewDomain != null &&
          normalizedNewDomain.isNotEmpty &&
          normalizedNewDomain != normalizedOldDomain) {
        final claimRef = _firestore
            .collection('customDomainClaims')
            .doc(normalizedNewDomain);
        final claimSnap = await claimRef.get();
        if (claimSnap.exists) {
          final claimedFacilityId = claimSnap.data()?['facilityId'];
          if (claimedFacilityId != facilityId) {
            throw Exception(
                'This domain is already connected to a different facility. Contact support if you believe this is an error.');
          }
          // Already claimed by this facility - do not re-set (rule denies update).
        } else {
          await claimRef.set({
            'facilityId': facilityId,
            'claimedAt': FieldValue.serverTimestamp(),
          });
        }
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('settings')
          .doc('public')
          .set(updatedSettings.toMap(), SetOptions(merge: true));

      if (normalizedOldDomain.isNotEmpty &&
          normalizedNewDomain != null &&
          normalizedNewDomain != normalizedOldDomain) {
        try {
          await _firestore
              .collection('customDomainClaims')
              .doc(normalizedOldDomain)
              .delete();
        } catch (e) {
          if (kDebugMode) {
            print(
                '⚠️ [FacilityPublic] Failed to release old domain claim: $e');
          }
        }
      }

      if (kDebugMode) {
        print(
            '✅ [FacilityPublic] Updated public settings for facility: $facilityId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [FacilityPublic] Error updating public settings: $e');
      }
      rethrow;
    }
  }

  /// Saves what Edit Facility's Public Rental Links section edits. There is
  /// no website parameter, so the facility keeps the website setting it has:
  /// [updatePublicSettings] keeps every field it is not given. Edit Facility
  /// used to pass `enabled: true`, so every save there turned the public
  /// website back on for an owner who had switched it off in Website Setup,
  /// or whose website add-on had lapsed, and the map publish that follows
  /// the save put it back on /w/{slug}.
  static Future<void> updateRentalSettings({
    required String facilityId,
    required bool publicRentalsEnabled,
    required String publicRentalSlug,
    bool? publicPricingEnabled,
    bool? publicUnitNumbersEnabled,
    bool? allowAutoAssign,
    bool? allowUnitSelection,
    bool? showAvailabilityCount,
    bool? hideUnavailableTypes,
    List<String>? enabledPublicUnitTypes,
  }) =>
      updatePublicSettings(
        facilityId: facilityId,
        publicRentalsEnabled: publicRentalsEnabled,
        publicRentalSlug: publicRentalSlug,
        publicPricingEnabled: publicPricingEnabled,
        publicUnitNumbersEnabled: publicUnitNumbersEnabled,
        allowAutoAssign: allowAutoAssign,
        allowUnitSelection: allowUnitSelection,
        showAvailabilityCount: showAvailabilityCount,
        hideUnavailableTypes: hideUnavailableTypes,
        enabledPublicUnitTypes: enabledPublicUnitTypes,
      );

  /// Saves what Website Setup edits. There is no online-rentals parameter,
  /// so the facility keeps the rentals setting it has: [updatePublicSettings]
  /// keeps every field it is not given. Website Setup used to pass
  /// `publicRentalsEnabled: true`, so every website save turned rentals back
  /// on for an owner who had switched them off in Edit Facility, and the
  /// public move-in callables then took holds and payments again.
  static Future<void> updateWebsiteSettings({
    required String facilityId,
    required bool enabled,
    required String publicRentalSlug,
    String? customDomain,
    String? pageTitle,
    String? pageDescription,
    String? marketingContent,
    List<String>? featuredImages,
    Map<String, dynamic>? customStyles,
    Map<String, dynamic>? widgets,
  }) =>
      updatePublicSettings(
        facilityId: facilityId,
        enabled: enabled,
        publicRentalSlug: publicRentalSlug,
        customDomain: customDomain,
        pageTitle: pageTitle,
        pageDescription: pageDescription,
        marketingContent: marketingContent,
        featuredImages: featuredImages,
        customStyles: customStyles,
        widgets: widgets,
      );

  /// Get facility by custom domain
  static Future<FacilityModel?> getFacilityByDomain(String domain) async {
    try {
      final snapshot = await _firestore
          .collectionGroup('settings')
          .where('customDomain', isEqualTo: domain)
          .where('enabled', isEqualTo: true)
          .limit(1)
          .get();

      if (snapshot.docs.isEmpty) return null;

      final settingsDoc = snapshot.docs.first;
      final facilityId = settingsDoc.reference.parent.parent?.id;

      if (facilityId == null) return null;

      final facilityDoc =
          await _firestore.collection('facilities').doc(facilityId).get();

      if (!facilityDoc.exists) return null;

      return FacilityModel.fromFirestore(facilityDoc);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [FacilityPublic] Error getting facility by domain: $e');
      }
      return null;
    }
  }

  /// Generate embed code for a widget
  static String generateWidgetEmbedCode({
    required String facilityId,
    required WidgetType widgetType,
    Map<String, dynamic>? widgetSettings,
    String? baseUrl,
  }) {
    final base = baseUrl ?? 'https://app.storagefacilitycreator.com';
    final widgetUrl = '$base/widget/$widgetType.name?facilityId=$facilityId';

    // Generate settings parameter if provided
    String settingsParam = '';
    if (widgetSettings != null && widgetSettings.isNotEmpty) {
      settingsParam =
          '&settings=${Uri.encodeComponent(widgetSettings.toString())}';
    }

    return '''
<script>
  (function() {
    var widget = document.createElement('iframe');
    widget.src = '$widgetUrl$settingsParam';
    widget.frameBorder = '0';
    widget.scrolling = 'no';
    widget.style.width = '100%';
    widget.style.minHeight = '600px';
    widget.style.border = 'none';
    document.currentScript.parentNode.insertBefore(widget, document.currentScript);
  })();
</script>
''';
  }

  /// Get public facility page URL
  static String getPublicPageUrl(String facilityId,
      {String? baseUrl, String? customDomain}) {
    if (customDomain != null && customDomain.isNotEmpty) {
      return 'https://$customDomain';
    }
    final base = baseUrl ?? 'https://app.storagefacilitycreator.com';
    return '$base/facility/$facilityId';
  }

  /// Get public map URL by slug.
  static String getPublicMapUrl(String facilitySlug, {String? baseUrl}) {
    final base = baseUrl ?? 'https://app.storagefacilitycreator.com';
    return '$base/#/public/$facilitySlug/map';
  }

  /// Get public rent URL by slug.
  static String getPublicRentUrl(String facilitySlug, {String? baseUrl}) {
    final base = baseUrl ?? 'https://app.storagefacilitycreator.com';
    return '$base/#/f/$facilitySlug/rent';
  }

  /// Get public available units URL by slug.
  static String getPublicAvailableUnitsUrl(String facilitySlug,
      {String? baseUrl}) {
    final base = baseUrl ?? 'https://app.storagefacilitycreator.com';
    return '$base/#/f/$facilitySlug/available-units';
  }

  /// Get public category URL by slug.
  static String getPublicCategoryUrl(
    String facilitySlug,
    String categorySlug, {
    String? baseUrl,
  }) {
    final base = baseUrl ?? 'https://app.storagefacilitycreator.com';
    return '$base/#/f/$facilitySlug/$categorySlug';
  }

  /// Get templated public website URL by slug (`/w/{slug}`).
  static String getPublicWebsiteUrl(String facilitySlug, {String? baseUrl}) {
    final base = baseUrl ?? 'https://app.storagefacilitycreator.com';
    return '$base/w/$facilitySlug';
  }

  /// Get website config JSON endpoint by slug.
  static String getPublicWebsiteConfigUrl(String facilitySlug,
      {String? baseUrl}) {
    final base = baseUrl ?? 'https://app.storagefacilitycreator.com';
    return '$base/api/public-website?slug=$facilitySlug';
  }

  /// Verifies if a custom domain appears configured for Firebase Hosting.
  static Future<DomainCheckResult> verifyCustomDomain(String domain) async {
    final normalized = _normalizeDomain(domain);
    if (normalized.isEmpty) {
      return const DomainCheckResult(
        isConnected: false,
        message: 'Enter a valid domain to check.',
      );
    }

    // Browser-side DNS lookups are blocked by CORS/CSP in production.
    // Keep this check local and deterministic so it never throws console errors.
    final labels = normalized.split('.');
    final looksValid = labels.length >= 2 &&
        labels.every((part) => RegExp(r'^[a-z0-9-]+$').hasMatch(part)) &&
        labels.every((part) => !part.startsWith('-') && !part.endsWith('-'));
    if (!looksValid) {
      return const DomainCheckResult(
        isConnected: false,
        message: 'Domain format looks invalid. Example: rent.yourdomain.com',
      );
    }
    return DomainCheckResult(
      isConnected: true,
      message:
          'Domain format looks valid. Use your browser to verify it resolves to this app.',
      records: <String>['https://$normalized'],
    );
  }

  static String _normalizeDomain(String value) {
    var cleaned = value.trim().toLowerCase();
    cleaned = cleaned.replaceFirst(RegExp(r'^https?://'), '');
    cleaned = cleaned.replaceFirst(RegExp(r'^www\.'), '');
    cleaned = cleaned.split('/').first;
    return cleaned;
  }
}

class DomainCheckResult {
  final bool isConnected;
  final String message;
  final List<String> records;

  const DomainCheckResult({
    required this.isConnected,
    required this.message,
    this.records = const <String>[],
  });
}
