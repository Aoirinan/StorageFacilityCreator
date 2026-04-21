/// App version constants
/// Update this file whenever deploying a new version
class AppVersion {
  // Version number (semver: major.minor.patch)
  static const String version = '2.10.25';

  // Build number (YYYYMMDD format for easy identification)
  static const String buildNumber = '20260422';

  // Full version string
  static const String fullVersion = '$version+$buildNumber';

  // Deployment date/time (update on each deploy)
  static const String deploymentDate = '2026-04-22';
  static const String deploymentTime =
      'Map editor: InteractiveViewer gesture lock; pointer-based corner resize; swap/rotate actions; build 20260422';

  // Feature version (what's in this release)
  static const String featureTag =
      'Map editor: viewport pan/zoom disabled while dragging or resizing so corners work on web. Resize uses raw pointers (not pan gestures). Shape sheet: swap width/height and rotate 90° (updates stored rotation).';

  // Full display string
  static String get displayVersion => 'v$version (Build $buildNumber)';

  // Detailed info for settings/about page
  static String get detailedVersion =>
      'Version $version\n'
      'Build $buildNumber\n'
      'Deployed: $deploymentDate ($deploymentTime)\n'
      'Features: $featureTag';
}
