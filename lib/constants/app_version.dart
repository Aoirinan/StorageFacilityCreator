/// App version constants
/// Update this file whenever deploying a new version
class AppVersion {
  // Version number (semver: major.minor.patch)
  static const String version = '2.10.23';

  // Build number (YYYYMMDD format for easy identification)
  static const String buildNumber = '20260419';

  // Full version string
  static const String fullVersion = '$version+$buildNumber';

  // Deployment date/time (update on each deploy)
  static const String deploymentDate = '2026-04-16';
  static const String deploymentTime =
      'Two-step permanent unit delete confirmations; renter SMS template helper; shared public-rental slug/domain normalization; build 20260419';

  // Feature version (what's in this release)
  static const String featureTag =
      'Unit list: double confirmation before permanent delete with clearer impact copy. Messaging: renter portal links template + greeting personalization. Online rentals: slug/domain helpers centralized.';

  // Full display string
  static String get displayVersion => 'v$version (Build $buildNumber)';

  // Detailed info for settings/about page
  static String get detailedVersion =>
      'Version $version\n'
      'Build $buildNumber\n'
      'Deployed: $deploymentDate ($deploymentTime)\n'
      'Features: $featureTag';
}
