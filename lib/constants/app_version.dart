/// App version constants
/// Update this file whenever deploying a new version
class AppVersion {
  // Version number (semver: major.minor.patch)
  static const String version = '2.10.5';
  
  // Build number (YYYYMMDD format for easy identification)
  static const String buildNumber = '20260303';
  
  // Full version string
  static const String fullVersion = '$version+$buildNumber';
  
  // Deployment date/time (update on each deploy)
  static const String deploymentDate = '2026-03-03';
  static const String deploymentTime = '11:07 UTC';
  
  // Feature version (what's in this release)
  static const String featureTag = 'QuickBooks: self-serve connect and automatic invoice/payment sync';
  
  // Full display string
  static String get displayVersion => 'v$version (Build $buildNumber)';
  
  // Detailed info for settings/about page
  static String get detailedVersion => 
      'Version $version\n'
      'Build $buildNumber\n'
      'Deployed: $deploymentDate at $deploymentTime\n'
      'Features: $featureTag';
}
