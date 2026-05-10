/// Fallback app version when [PackageInfo] is unavailable (tests, early frame).
/// **Keep in sync with `pubspec.yaml`** `version:` line (`major.minor.patch+build`).
class AppVersion {
  static const String version = '2.10.68';

  static const String buildNumber = '20260510';

  static const String fullVersion = '$version+$buildNumber';

  static const String deploymentDate = '2026-05-10';
  static const String deploymentTime =
      'Release readiness CI paths; remove unused facility-ops firestore duplicate.';

  static const String featureTag =
      'Hosting build; CI email limits + QuickBooks checks aligned with shared packages.';

  static String get displayVersion => 'v$version (Build $buildNumber)';

  static String get detailedVersion => 'Version $version\n'
      'Build $buildNumber\n'
      'Deployed: $deploymentDate ($deploymentTime)\n'
      'Features: $featureTag';
}
