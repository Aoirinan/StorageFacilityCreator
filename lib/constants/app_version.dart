/// App version constants
/// Update this file whenever deploying a new version
class AppVersion {
  // Version number (semver: major.minor.patch)
  static const String version = '2.10.35';

  // Build number (YYYYMMDD format for easy identification)
  static const String buildNumber = '20260422';

  // Full version string
  static const String fullVersion = '$version+$buildNumber';

  // Deployment date/time (update on each deploy)
  static const String deploymentDate = '2026-04-22';
  static const String deploymentTime =
      'Tenant portal additional-unit rental linking with secure portal hold flow; online rentals compatibility hardening.';

  // Feature version (what's in this release)
  static const String featureTag =
      'Tenant portal multi-unit aggregation, per-unit portal payments, and safe additional-unit move-in linking.';

  // Full display string
  static String get displayVersion => 'v$version (Build $buildNumber)';

  // Detailed info for settings/about page
  static String get detailedVersion =>
      'Version $version\n'
      'Build $buildNumber\n'
      'Deployed: $deploymentDate ($deploymentTime)\n'
      'Features: $featureTag';
}
