/// Fallback app version when [PackageInfo] is unavailable (tests, early frame).
/// **Keep in sync with `pubspec.yaml`** `version:` line (`major.minor.patch+build`).
class AppVersion {
  static const String version = '2.11.6';

  static const String buildNumber = '20260724';

  static const String fullVersion = '$version+$buildNumber';

  static const String deploymentDate = '2026-07-18';
  static const String deploymentTime =
      'DNR compliance release: accuracy attestation, participation terms gating, superadmin DNR moderation tab, modernized DNR screens, and audit-logged DNR changes.';

  static const String featureTag =
      'DNR attestation + participation gate; DNR moderation tab; staff person picker; modern DNR entry/detail UI; single facility selector.';

  static String get displayVersion => 'v$version (Build $buildNumber)';

  static String get detailedVersion => 'Version $version\n'
      'Build $buildNumber\n'
      'Deployed: $deploymentDate ($deploymentTime)\n'
      'Features: $featureTag';
}
