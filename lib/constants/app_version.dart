/// Fallback app version when [PackageInfo] is unavailable (tests, early frame).
/// **Keep in sync with `pubspec.yaml`** `version:` line (`major.minor.patch+build`).
class AppVersion {
  static const String version = '2.10.48';

  static const String buildNumber = '20260424';

  static const String fullVersion = '$version+$buildNumber';

  static const String deploymentDate = '2026-04-25';
  static const String deploymentTime =
      'Super Admin custom domain provisioning + Hosting root routing for vanity domains.';

  static const String featureTag =
      'Custom domain DNS provisioning UI + marketing apex redirect.';

  static String get displayVersion => 'v$version (Build $buildNumber)';

  static String get detailedVersion => 'Version $version\n'
      'Build $buildNumber\n'
      'Deployed: $deploymentDate ($deploymentTime)\n'
      'Features: $featureTag';
}
