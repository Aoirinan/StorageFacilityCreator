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

## Hosting source of truth (do not mix these up)

| Surface | Folder | Goes live via |
|--------|--------|----------------|
| **Marketing / SEO site** | `marketing/` | **Vercel** (push to `main` when Git is connected) → `https://www.storagefacilitycreator.com` |
| **Operator Flutter app** | repo root (`lib/`, …) | **Firebase Hosting** → run **`./deploy.ps1`** (push to GitHub does **not** update Firebase by itself unless you added CI) |

Details: [docs/DEPLOY_MARKETING_VS_APP.md](docs/DEPLOY_MARKETING_VS_APP.md) · Search Console + optional DNS: [docs/SEO_SETUP_CHECKLIST.md](docs/SEO_SETUP_CHECKLIST.md)

## Flutter Web Build (App)
- Build with cache busting: `./build_web_with_cache_bust.ps1`
- Outputs to `build/web` with hashed assets.
- Serve locally: `flutter run -d chrome --release`.
- Release build (skip WASM dry run): `flutter build web --release --no-wasm-dry-run`.
- Optional deploy target: Firebase Hosting app endpoints (`*.web.app`, `*.firebaseapp.com`), not the primary marketing domain.

## Website Deploy (Next.js on Vercel)
- Website source is `marketing`.
- Local run: `cd marketing && npm run dev` (http://localhost:3000).
- Production build check: `cd marketing && npm run build`.
- Deploy via Vercel with root directory set to `marketing`.

## Common Web Tips
- Startup: on Firebase init failure, use the Retry button; check console for details.
- Focus noise on web is suppressed; other platform errors bubble to crash reporting hook.
- For subscription access issues, ensure network connectivity; guard is fail-closed on errors.

## Manager Overlock
Manager Overlock is a manager/admin-only feature for marking units as overlocked (e.g. for non-payment or policy).

### UI
- **Nav:** Left sidebar → "Manager Overlock" (under Delinquency).
- **Page:** Facility filter, search (name, unit #, phone, email), filters: Overlock status (All / Overlocked / Not Overlocked), Delinquency (All / Delinquent Only / Not Delinquent).
- **Bulk actions:** Select rows → Overlock Selected, Remove Overlock Selected, Overlock All Delinquent, Clear Overlock All (Filtered; requires typing CLEAR), Print Overlock List.
- **Table:** Unit #, Tenant, Phone/Email, Balance, Overlock badge, per-row Mark Overlocked / Remove Overlock. Row click opens a detail drawer with overlock history and quick toggle.
- **Print:** "Print Overlock List" opens a printable view (overlocked units only by default); use the Print icon or browser Print (e.g. Ctrl+P) to print.

### Data
- **Unit document** (`facilities/{facilityId}/units/{unitId}`): `overlock` map with `isOverlocked`, `updatedAt`, `updatedByUid`, `updatedByName`, `reasonNote`, `lastAction` ("OVERLOCKED" | "REMOVED").
- **Audit subcollection** `facilities/{facilityId}/units/{unitId}/overlockEvents/{eventId}`: `action`, `at`, `byUid`, `byName`, `note`, `tenantId`, `tenantName`, optional `bulkBatchId`.
- **Tenant document:** Denormalized `overlockIsActive` (boolean), kept in sync by Cloud Functions.

### Backend
- Callables: `setUnitOverlockStatus`, `setUnitsOverlockStatusBulk`, `overlockAllDelinquent`, `clearOverlockByFilter`. All require manager/admin for the facility; note required when setting overlock.
- Firestore rules: only owner/manager can update unit overlock and create overlockEvents.

### Where overlock appears
- Unit list: red "OVERLOCKED" badge next to status.
- Map editor: "OVERLOCKED" label on unit tile.
- Tenant (client) detail: red banner "Unit is overlocked".
- Tenant portal: warning banner "Unit is currently overlocked. Please contact management." Payments remain allowed.
