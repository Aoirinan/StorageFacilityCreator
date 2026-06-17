/// Fallback app version when [PackageInfo] is unavailable (tests, early frame).
/// **Keep in sync with `pubspec.yaml`** `version:` line (`major.minor.patch+build`).
class AppVersion {
  static const String version = '2.10.70';

  static const String buildNumber = '20260617';

  static const String fullVersion = '$version+$buildNumber';

  static const String deploymentDate = '2026-06-17';
  static const String deploymentTime =
      'Regression coverage, portal payments, facility stats healing, rent payments hub, super admin platform tools, neutral compare page, and IP-safe positioning cleanup.';

  static const String featureTag =
      'Rent payments shell; Firestore index UX; Stripe Connect checklist; platform reset tab; facility stats fixes.';

  static String get displayVersion => 'v$version (Build $buildNumber)';

  static String get detailedVersion => 'Version $version\n'
      'Build $buildNumber\n'
      'Deployed: $deploymentDate ($deploymentTime)\n'
      'Features: $featureTag';
}
