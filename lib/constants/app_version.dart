/// Fallback app version when [PackageInfo] is unavailable (tests, early frame).
/// **Keep in sync with `pubspec.yaml`** `version:` line (`major.minor.patch+build`).
class AppVersion {
  static const String version = '2.10.45';

  static const String buildNumber = '20260424';

  static const String fullVersion = '$version+$buildNumber';

  static const String deploymentDate = '2026-04-24';
  static const String deploymentTime =
      'Sidebar version now reads from package_info (pubspec).';

  static const String featureTag =
      'Version display matches each web build; super-admin tab icons.';

  static String get displayVersion => 'v$version (Build $buildNumber)';

  static String get detailedVersion =>
      'Version $version\n'
      'Build $buildNumber\n'
      'Deployed: $deploymentDate ($deploymentTime)\n'
      'Features: $featureTag';
}
