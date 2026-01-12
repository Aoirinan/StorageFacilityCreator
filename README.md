# SFC App (Web)

Flutter web app for Storage Facility Creator.

## Quick Start

1) Install Flutter 3.10+ and run `flutter pub get`.
2) Optional: use Firebase emulators in debug:
   `flutter run -d chrome --dart-define=USE_EMULATORS=true`.
3) Run app: `flutter run -d chrome`.

## Quality Gates
- Analyze: `flutter analyze`
- Tests (with Firebase mocks): `flutter test`

## Web Build & Deploy
- Build with cache busting: `./build_web_with_cache_bust.ps1`
- Outputs to `build/web` with hashed assets.
- Serve locally: `flutter run -d chrome --release`.
- Deploy: upload `build/web` to hosting of choice (Firebase Hosting/CDN) and ensure cache headers respect hashes.

## Common Web Tips
- Startup: on Firebase init failure, use the Retry button; check console for details.
- Focus noise on web is suppressed; other platform errors bubble to crash reporting hook.
- For subscription access issues, ensure network connectivity; guard is fail-closed on errors.
