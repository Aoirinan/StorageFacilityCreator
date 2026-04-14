import 'package:flutter/foundation.dart' show kIsWeb;

/// Public marketing site (Vercel).
const String kMarketingWebsiteOrigin = 'https://storagefacilitycreator.com';

/// Flutter app host used for staff login and operational deep links.
const String kAppWebHostname = 'app.storagefacilitycreator.com';

/// Production app subdomain: no duplicate marketing stack; entry is login.
bool isProductionAppWebHost() {
  if (!kIsWeb) return false;
  return Uri.base.host.toLowerCase() == kAppWebHostname;
}
