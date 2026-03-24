import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/facility_public_settings_model.dart';
import '../models/facility_model.dart';

/// Service for managing public facility pages and widgets
class FacilityPublicService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Get public settings for a facility
  static Future<FacilityPublicSettings?> getPublicSettings(
      String facilityId) async {
    try {
      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('settings')
          .doc('public')
          .get();

      if (!doc.exists) {
        // Return default settings
        return FacilityPublicSettings(facilityId: facilityId);
      }

      return FacilityPublicSettings.fromMap(doc.data()!);
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
    Map<String, dynamic>? customStyles,
    Map<String, dynamic>? widgets,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final currentSettings = await getPublicSettings(facilityId);
      final updatedSettings = FacilityPublicSettings(
        facilityId: facilityId,
        enabled: enabled ?? currentSettings?.enabled ?? false,
        publicRentalsEnabled: publicRentalsEnabled ??
            currentSettings?.publicRentalsEnabled ??
            false,
        publicPricingEnabled: publicPricingEnabled ??
            currentSettings?.publicPricingEnabled ??
            true,
        publicUnitNumbersEnabled: publicUnitNumbersEnabled ??
            currentSettings?.publicUnitNumbersEnabled ??
            true,
        allowAutoAssign:
            allowAutoAssign ?? currentSettings?.allowAutoAssign ?? true,
        allowUnitSelection:
            allowUnitSelection ?? currentSettings?.allowUnitSelection ?? true,
        showAvailabilityCount: showAvailabilityCount ??
            currentSettings?.showAvailabilityCount ??
            true,
        hideUnavailableTypes: hideUnavailableTypes ??
            currentSettings?.hideUnavailableTypes ??
            true,
        enabledPublicUnitTypes: enabledPublicUnitTypes ??
            currentSettings?.enabledPublicUnitTypes ??
            const <String>[],
        publicRentalSlug: publicRentalSlug ?? currentSettings?.publicRentalSlug,
        customDomain: customDomain ?? currentSettings?.customDomain,
        publicLogoUrl: publicLogoUrl ?? currentSettings?.publicLogoUrl,
        marketingContent: marketingContent ?? currentSettings?.marketingContent,
        unitTypeImageUrls:
            unitTypeImageUrls ?? currentSettings?.unitTypeImageUrls,
        pageTitle: pageTitle ?? currentSettings?.pageTitle,
        pageDescription: pageDescription ?? currentSettings?.pageDescription,
        featuredImages: featuredImages ?? currentSettings?.featuredImages,
        showAvailableUnits:
            showAvailableUnits ?? currentSettings?.showAvailableUnits ?? true,
        allowOnlineReservations: allowOnlineReservations ??
            currentSettings?.allowOnlineReservations ??
            true,
        allowOnlineMoveIn:
            allowOnlineMoveIn ?? currentSettings?.allowOnlineMoveIn ?? false,
        customStyles: customStyles ?? currentSettings?.customStyles,
        widgets: widgets ?? currentSettings?.widgets,
        updatedAt: DateTime.now(),
        updatedBy: user.uid,
      );

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('settings')
          .doc('public')
          .set(updatedSettings.toMap(), SetOptions(merge: true));

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
