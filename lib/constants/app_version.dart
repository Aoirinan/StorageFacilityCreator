/// App version constants
/// Update this file whenever deploying a new version
class AppVersion {
  // Version number (semver: major.minor.patch)
  static const String version = '2.10.19';

  // Build number (YYYYMMDD format for easy identification)
  static const String buildNumber = '20260415';

  // Full version string
  static const String fullVersion = '$version+$buildNumber';

  // Deployment date/time (update on each deploy)
  static const String deploymentDate = '2026-04-15';
  static const String deploymentTime = 'synced with pubspec deploy';

  // Feature version (what's in this release)
  static const String featureTag =
      'Retail: sidebar Retail → POS with facility resolution; POS ↔ Inventory; tenant Store sale; payments/print/billing panel updates';

  // Full display string
  static String get displayVersion => 'v$version (Build $buildNumber)';

  // Detailed info for settings/about page
  static String get detailedVersion =>
      'Version $version\n'
      'Build $buildNumber\n'
      'Deployed: $deploymentDate ($deploymentTime)\n'
      'Features: $featureTag';
}
