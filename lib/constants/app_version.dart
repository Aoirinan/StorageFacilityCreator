/// Fallback app version when [PackageInfo] is unavailable (tests, early frame).
/// **Keep in sync with `pubspec.yaml`** `version:` line (`major.minor.patch+build`).
class AppVersion {
  static const String version = '2.10.69';

  static const String buildNumber = '20260615';

  static const String fullVersion = '$version+$buildNumber';

  static const String deploymentDate = '2026-06-15';
  static const String deploymentTime =
      'Security remediation: portal auth hardening, signing-token validation, scoped user lookup.';

  static const String featureTag =
      'Remove ownership-hijack callable; portal rate limits; mergeSignatureIntoPdf SSRF fix.';

  static String get displayVersion => 'v$version (Build $buildNumber)';

  static String get detailedVersion => 'Version $version\n'
      'Build $buildNumber\n'
      'Deployed: $deploymentDate ($deploymentTime)\n'
      'Features: $featureTag';
}
