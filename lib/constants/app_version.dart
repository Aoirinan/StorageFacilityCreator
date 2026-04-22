/// App version constants
/// Update this file whenever deploying a new version
class AppVersion {
  // Version number (semver: major.minor.patch)
  static const String version = '2.10.28';

  // Build number (YYYYMMDD format for easy identification)
  static const String buildNumber = '20260424';

  // Full version string
  static const String fullVersion = '$version+$buildNumber';

  // Deployment date/time (update on each deploy)
  static const String deploymentDate = '2026-04-24';
  static const String deploymentTime =
      'Map editor: copy/paste unassigned blocks, duplicate row to the right, scrollable toolbar.';

  // Feature version (what's in this release)
  static const String featureTag =
      'Web: rebuild and redeploy hosting so the sidebar shows this version (avoids stale main.dart.js).';

  // Full display string
  static String get displayVersion => 'v$version (Build $buildNumber)';

  // Detailed info for settings/about page
  static String get detailedVersion =>
      'Version $version\n'
      'Build $buildNumber\n'
      'Deployed: $deploymentDate ($deploymentTime)\n'
      'Features: $featureTag';
}
