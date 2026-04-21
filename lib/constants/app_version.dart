/// App version constants
/// Update this file whenever deploying a new version
class AppVersion {
  // Version number (semver: major.minor.patch)
  static const String version = '2.10.24';

  // Build number (YYYYMMDD format for easy identification)
  static const String buildNumber = '20260421';

  // Full version string
  static const String fullVersion = '$version+$buildNumber';

  // Deployment date/time (update on each deploy)
  static const String deploymentDate = '2026-04-21';
  static const String deploymentTime =
      'Map editor V2: web toolbar zoom icons; resize handles no longer removed on pointer down; build 20260421';

  // Feature version (what's in this release)
  static const String featureTag =
      'Map editor: reliable zoom controls on web (Material icon tree-shake). Resizing unit boxes works again (Listener scoped to body, handles stay mounted while resizing).';

  // Full display string
  static String get displayVersion => 'v$version (Build $buildNumber)';

  // Detailed info for settings/about page
  static String get detailedVersion =>
      'Version $version\n'
      'Build $buildNumber\n'
      'Deployed: $deploymentDate ($deploymentTime)\n'
      'Features: $featureTag';
}
