/// Fallback app version when [PackageInfo] is unavailable (tests, early frame).
/// **Keep in sync with `pubspec.yaml`** `version:` line (`major.minor.patch+build`).
class AppVersion {
  static const String version = '2.13.0';

  static const String buildNumber = '20260803';

  static const String fullVersion = '$version+$buildNumber';

  static const String deploymentDate = '2026-08-03';
  static const String deploymentTime =
      'Cancellation retention flow, superadmin website-subscription admin tools, and custom domain hosting fixes.';

  static const String featureTag =
      'Subscription cancellation with retention offers; superadmin retention/websites tabs; custom domain DNS/status fixes.';

  static String get displayVersion => 'v$version (Build $buildNumber)';

  static String get detailedVersion => 'Version $version\n'
      'Build $buildNumber\n'
      'Deployed: $deploymentDate ($deploymentTime)\n'
      'Features: $featureTag';
}
