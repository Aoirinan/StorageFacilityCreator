/// App version constants
/// Update this file whenever deploying a new version
class AppVersion {
  // Version number (semver: major.minor.patch)
  static const String version = '2.10.21';

  // Build number (YYYYMMDD format for easy identification)
  static const String buildNumber = '20260417';

  // Full version string
  static const String fullVersion = '$version+$buildNumber';

  // Deployment date/time (update on each deploy)
  static const String deploymentDate = '2026-04-16';
  static const String deploymentTime =
      'Platform-wide Global DNR: screening merges global_dnr_entries; copy and rules comments; build 20260417';

  // Feature version (what's in this release)
  static const String featureTag =
      'Global DNR is platform-wide across all SFC operators; contract and DNR screening include global_dnr_entries';

  // Full display string
  static String get displayVersion => 'v$version (Build $buildNumber)';

  // Detailed info for settings/about page
  static String get detailedVersion =>
      'Version $version\n'
      'Build $buildNumber\n'
      'Deployed: $deploymentDate ($deploymentTime)\n'
      'Features: $featureTag';
}
