import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Whether a facility's public website (`/w/{slug}`) is live.
///
/// `/w/{slug}` (renderPublicWebsite) answers "Website not found" unless the
/// facility's `publicFacilityMaps/{slug}.publicSettings.enabled` is true and
/// the facility is entitled to the website (billing exempt, an active website
/// add-on, or a super admin trial). The entitlement is on the facility doc,
/// which a renter cannot read, so this asks `/api/public-website?slug=`
/// (getPublicWebsiteConfig), which applies the same gate and answers 404
/// when it fails.
class PublicWebsiteStatus {
  PublicWebsiteStatus._();

  static const Duration _timeout = Duration(seconds: 6);

  /// The origin the app is served from, which also serves `/w/**` and
  /// `/api/public-website` (firebase.json). Off the web there is no page
  /// origin, so this is the production app.
  static Uri appOrigin() {
    final base = Uri.base;
    if (base.scheme == 'http' || base.scheme == 'https') {
      return Uri.parse(base.origin);
    }
    return Uri.parse('https://app.storagefacilitycreator.com');
  }

  /// The website's unit list, where the rent links send renters when the
  /// website is live.
  static Uri websiteUnitsUrl(String slug, {Uri? origin}) =>
      (origin ?? appOrigin()).replace(
        path: '/w/$slug',
        fragment: 'unit-list',
      );

  /// True only when the server answers with the website's config. A 404,
  /// any other status, a body that is not the config (a local dev server
  /// answers every path with index.html), a timeout or a network failure all
  /// count as not live: the rental portal works either way and the website
  /// does not, so the portal is the safe side to be wrong on.
  static Future<bool> isLive(
    String slug, {
    http.Client? client,
    Uri? origin,
  }) async {
    final trimmed = slug.trim();
    if (trimmed.isEmpty) return false;
    final url = (origin ?? appOrigin()).replace(
      path: '/api/public-website',
      queryParameters: {'slug': trimmed},
    );
    final owned = client == null;
    final c = client ?? http.Client();
    try {
      final res = await c.get(url).timeout(_timeout);
      if (res.statusCode != 200) return false;
      final body = jsonDecode(res.body);
      if (body is! Map) return false;
      final servedSlug = body['facilitySlug'];
      return servedSlug is String && servedSlug.trim().isNotEmpty;
    } catch (_) {
      return false;
    } finally {
      if (owned) c.close();
    }
  }
}
