/// Fallback app version when [PackageInfo] is unavailable (tests, early frame).
/// **Keep in sync with `pubspec.yaml`** `version:` line (`major.minor.patch+build`).
class AppVersion {
  static const String version = '2.10.66';

  static const String buildNumber = '20260509';

  static const String fullVersion = '$version+$buildNumber';

  static const String deploymentDate = '2026-05-09';
  static const String deploymentTime =
      'Autopay revenue in facility stats; CF triggers mirror unitDocCount; metrics backfill.';

  static const String featureTag =
      'Facility stats: autopayMonthlyRevenue + server/client unit count parity.';

  static String get displayVersion => 'v$version (Build $buildNumber)';

  static String get detailedVersion => 'Version $version\n'
      'Build $buildNumber\n'
      'Deployed: $deploymentDate ($deploymentTime)\n'
      'Features: $featureTag';
}
