# Deployment Instructions - Facility Scoping Fixes

## Quick Deploy

Run the deployment script:

```powershell
.\deploy.ps1
```

## Manual Deployment Steps

If you prefer to deploy manually:

### 1. Build Flutter Web App

```powershell
flutter pub get
flutter build web --release --no-wasm-dry-run
```

### 2. Deploy Firestore Rules & Indexes

```powershell
firebase deploy --only firestore:rules,firestore:indexes
```

### 3. Deploy Hosting

```powershell
firebase deploy --only hosting:prod
```

### 4. (Optional) Deploy Cloud Functions

Only needed if you modified functions:

```powershell
cd functions
npm install
npm run build
cd ..
firebase deploy --only functions
```

## What's Being Deployed

### ✅ New Features
- **Active Facility Switcher** - Global facility selector in top bar
- **Dashboard Filtering** - Dashboard now filters by active facility
- **Stripe Connect Per-Facility** - Each facility has its own Stripe Connect account
- **Accurate Unit Counts** - Facility cards compute counts on-the-fly

### 📁 Files Changed
- `lib/services/active_facility_service.dart` (NEW)
- `lib/providers/active_facility_provider.dart` (NEW)
- `lib/widgets/facility_switcher.dart` (NEW)
- `lib/services/facility_stats_service.dart` (NEW)
- `lib/models/user_model.dart` (MODIFIED - added activeFacilityId)
- `lib/providers/dashboard_provider.dart` (MODIFIED - filters by active facility)
- `lib/screens/home_screen_modern.dart` (MODIFIED - added switcher)
- `lib/screens/facility_management_screen.dart` (MODIFIED - compute counts)
- `lib/screens/settings_screen.dart` (MODIFIED - use active facility)
- `lib/router/app_router.dart` (MODIFIED - Stripe Connect routing)

### 🔥 Firestore Changes
- **New Field**: `users/{uid}/activeFacilityId` (nullable string)
- **No Migration Needed**: Existing users default to "All Facilities" (null)

## Post-Deployment Testing

### 1. Facility Switcher
- [ ] Login to the app
- [ ] If you have 2+ facilities, verify switcher appears in top bar
- [ ] Select a facility and verify dashboard updates
- [ ] Select "All Facilities" and verify aggregated data

### 2. Dashboard Filtering
- [ ] Switch between facilities and verify metrics change
- [ ] Verify unit counts match facility cards
- [ ] Check that tenant/payment counts are filtered correctly

### 3. Stripe Connect
- [ ] Go to Settings → Payment Processing
- [ ] Verify it shows the active facility's Stripe account
- [ ] Create Stripe Connect account for Facility A
- [ ] Switch to Facility B
- [ ] Verify Facility B has its own separate Stripe account

### 4. Facility Unit Counts
- [ ] Go to Facilities page
- [ ] Verify unit counts (X/Y occupied) are accurate
- [ ] Create a new unit and verify count updates
- [ ] Move a tenant in/out and verify occupied count updates

### 5. Billing
- [ ] Create first facility (should work without subscription)
- [ ] Try to create second facility (should prompt for subscription)
- [ ] After subscribing, verify second facility creation works
- [ ] Check Stripe subscription quantity = 1 base + (N-1) add-ons

## Troubleshooting

### Build Fails
- Ensure Flutter 3.10+ is installed: `flutter --version`
- Clear build cache: `flutter clean && flutter pub get`

### Firestore Deployment Fails
- Check you're logged in: `firebase login`
- Verify project: `firebase projects:list`
- Check rules syntax: `firebase deploy --only firestore:rules --dry-run`

### Hosting Deployment Fails
- Verify build output exists: `Test-Path build/web/index.html`
- Check Firebase project: `firebase use storage-facility-creator`

### Functions Deployment Fails
- Install dependencies: `cd functions && npm install`
- Build TypeScript: `npm run build`
- Check for TypeScript errors: `npm run build`

## Rollback (If Needed)

If you need to rollback:

```powershell
# Revert to previous hosting version
firebase hosting:rollback

# Or redeploy previous build
git checkout <previous-commit>
.\deploy.ps1
```

## Support

See `docs/FACILITY_SCOPING_FIXES.md` for detailed documentation of all changes.
