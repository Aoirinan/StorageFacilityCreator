/// Fallback app version when [PackageInfo] is unavailable (tests, early frame).
/// **Keep in sync with `pubspec.yaml`** `version:` line (`major.minor.patch+build`).
class AppVersion {
  static const String version = '2.10.67';

  static const String buildNumber = '20260509';

  static const String fullVersion = '$version+$buildNumber';

  static const String deploymentDate = '2026-05-09';
  static const String deploymentTime =
      'Dashboard + super-admin Metrics show scheduled MRR and autopay portion.';

  static const String featureTag =
      'Tenant MRR and autopay surfaced in UI; platform aggregate from stats cache.';

  static String get displayVersion => 'v$version (Build $buildNumber)';

  static String get detailedVersion => 'Version $version\n'
      'Build $buildNumber\n'
      'Deployed: $deploymentDate ($deploymentTime)\n'
      'Features: $featureTag';
}
