import '../models/facility_model.dart';
import '../services/facility_map_v2_service.dart';
import '../services/facility_public_service.dart';
import '../services/facility_service.dart';

/// Same rules as online rental slug field.
String normalizePublicRentalSlug(String value) {
  return value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9-]'), '-')
      .replaceAll(RegExp(r'-{2,}'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
}

/// Host only, lowercased, no scheme or path.
String normalizeCustomDomain(String value) {
  var cleaned = value.trim().toLowerCase();
  cleaned = cleaned.replaceFirst(RegExp(r'^https?://'), '');
  cleaned = cleaned.replaceFirst(RegExp(r'^www\.'), '');
  cleaned = cleaned.split('/').first;
  return cleaned;
}

String linkBaseUrlFromCustomDomainField(String customDomainFieldText) {
  final domain = normalizeCustomDomain(customDomainFieldText);
  if (domain.isNotEmpty) {
    return 'https://$domain';
  }
  return 'https://app.storagefacilitycreator.com';
}

/// SMS/email-friendly template: facility links are filled in; amount and pay URL
/// come from Payment Links (per tenant).
String buildRenterAccountMessage({
  required FacilityModel? facility,
  required String slug,
  required String linkBaseUrl,
}) {
  final facilityName = facility?.name ?? 'Our facility';
  final rentUrl = FacilityPublicService.getPublicRentUrl(
    slug,
    baseUrl: linkBaseUrl,
  );
  final portalUrl = '$linkBaseUrl/#/tenant-portal';
  final phone = facility?.phone?.trim();
  final phoneBlock = (phone != null && phone.isNotEmpty)
      ? 'Questions? Call us at $phone.\n\n'
      : '';

  return '''Hi,

This is $facilityName. Here is what you need for online rentals and your account:

Rent or reserve a unit online:
$rentUrl

See your balance and sign in to the tenant portal:
$portalUrl

Amount due: \$[AMOUNT]
Pay securely (paste the one-time link from our office software):
[PAYMENT_LINK]

The payment page shows the amount before you check out. After you pay, it updates your account automatically—no need to send a receipt.

$phoneBlock$facilityName''';
}

/// Loads saved public-rental settings and builds [buildRenterAccountMessage].
Future<String> buildRenterAccountMessageForFacilityId(String facilityId) async {
  final facility = await FacilityService.getFacility(facilityId);
  final settings =
      await FacilityPublicService.getPublicSettings(facilityId);
  final publicSlug =
      await FacilityMapV2Service.getPublicSlugForFacility(facilityId);
  final rawSlug = (settings?.publicRentalSlug?.trim().isNotEmpty ?? false)
      ? settings!.publicRentalSlug!
      : (publicSlug ?? facilityId.toLowerCase());
  final slug = normalizePublicRentalSlug(rawSlug);
  final effectiveSlug = slug.isEmpty ? facilityId.toLowerCase() : slug;
  final linkBaseUrl =
      linkBaseUrlFromCustomDomainField(settings?.customDomain ?? '');
  return buildRenterAccountMessage(
    facility: facility,
    slug: effectiveSlug,
    linkBaseUrl: linkBaseUrl,
  );
}
