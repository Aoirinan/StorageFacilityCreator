/// App version constants
/// Update this file whenever deploying a new version
class AppVersion {
  // Version number (semver: major.minor.patch)
  static const String version = '2.10.26';

  // Build number (YYYYMMDD format for easy identification)
  static const String buildNumber = '20260423';

  // Full version string
  static const String fullVersion = '$version+$buildNumber';

  // Deployment date/time (update on each deploy)
  static const String deploymentDate = '2026-04-23';
  static const String deploymentTime =
      'Units: sidebar navigation from Map Editor to Unit List; New Unit opens create flow (/units/create).';

  // Feature version (what's in this release)
  static const String featureTag =
      'Fix ModernNavigationService treating /units/map as /units (Unit List sidebar works from map). Add /units/create route; Unit List New Unit opens UnitCreationScreen.';

  // Full display string
  static String get displayVersion => 'v$version (Build $buildNumber)';

  // Detailed info for settings/about page
  static String get detailedVersion =>
      'Version $version\n'
      'Build $buildNumber\n'
      'Deployed: $deploymentDate ($deploymentTime)\n'
      'Features: $featureTag';
}
