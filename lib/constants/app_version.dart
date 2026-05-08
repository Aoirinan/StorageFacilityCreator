/// Fallback app version when [PackageInfo] is unavailable (tests, early frame).
/// **Keep in sync with `pubspec.yaml`** `version:` line (`major.minor.patch+build`).
class AppVersion {
  static const String version = '2.10.64';

  static const String buildNumber = '20260504';

  static const String fullVersion = '$version+$buildNumber';

  static const String deploymentDate = '2026-05-04';
  static const String deploymentTime =
      'Dashboard unit capacity labeling; no auto-create placeholder unit rows on sync.';

  static const String featureTag =
      'Facility capacity vs unit records; super admin messaging UX.';

  static String get displayVersion => 'v$version (Build $buildNumber)';

  static String get detailedVersion => 'Version $version\n'
      'Build $buildNumber\n'
      'Deployed: $deploymentDate ($deploymentTime)\n'
      'Features: $featureTag';
}
