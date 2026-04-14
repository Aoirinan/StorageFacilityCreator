# Deployment script for Storage Facility Creator
# Deploys Flutter web app, Firestore rules, Storage rules, and hosting

Write-Host ''
Write-Host 'Starting deployment...' -ForegroundColor Green

# Step 1: Check Flutter installation
Write-Host ''
Write-Host 'Step 1: Checking Flutter installation...' -ForegroundColor Cyan
flutter --version
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Flutter not found. Please install Flutter first.' -ForegroundColor Red
    exit 1
}

# Step 2: Get dependencies
Write-Host ''
Write-Host 'Step 2: Getting Flutter dependencies...' -ForegroundColor Cyan
flutter pub get
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Failed to get dependencies' -ForegroundColor Red
    exit 1
}

# Step 3: Clean and build (clean ensures new version number is in the bundle)
Write-Host ''
Write-Host 'Step 3a: Cleaning previous build...' -ForegroundColor Cyan
flutter clean
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Flutter clean failed' -ForegroundColor Red
    exit 1
}
Write-Host ''
Write-Host 'Step 3b: Building Flutter web app in release mode...' -ForegroundColor Cyan
flutter pub get
flutter build web --release --no-wasm-dry-run
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Build failed' -ForegroundColor Red
    exit 1
}
Write-Host 'Build successful!' -ForegroundColor Green

# Verify build output
$idx = "build\web\index.html"
$bootstrap = "build\web\flutter_bootstrap.js"
if (-not (Test-Path $idx)) {
    Write-Host 'Build incomplete: index.html not found.' -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $bootstrap)) {
    Write-Host 'Build incomplete: flutter_bootstrap.js not found.' -ForegroundColor Red
    exit 1
}
Write-Host 'Build output verified.' -ForegroundColor Green

# Step 4: Deploy Cloud Functions (includes new attachTenantPaymentMethodFromRedirect for Stripe Link)
Write-Host ''
Write-Host 'Step 4a: Deploying Cloud Functions...' -ForegroundColor Cyan
firebase deploy --only functions
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Functions deployment failed' -ForegroundColor Red
    exit 1
}
Write-Host 'Cloud Functions deployed!' -ForegroundColor Green

# Step 5: Deploy Firestore rules and indexes
Write-Host ''
Write-Host 'Step 5: Deploying Firestore rules and indexes...' -ForegroundColor Cyan
firebase deploy --only firestore:rules,firestore:indexes
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Firestore deployment failed' -ForegroundColor Red
    exit 1
}
Write-Host 'Firestore rules and indexes deployed!' -ForegroundColor Green

# Step 6: Deploy Storage (required for DNR evidence uploads and other file uploads)
Write-Host ''
Write-Host 'Step 6: Deploying Storage rules...' -ForegroundColor Cyan
firebase deploy --only storage
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Storage deployment failed' -ForegroundColor Red
    exit 1
}
Write-Host 'Storage rules deployed!' -ForegroundColor Green

# Step 7: Deploy hosting
Write-Host ''
Write-Host 'Step 7: Deploying web hosting...' -ForegroundColor Cyan
firebase deploy --only hosting
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Hosting deployment failed' -ForegroundColor Red
    exit 1
}
Write-Host 'Hosting deployed!' -ForegroundColor Green

Write-Host ''
Write-Host 'Deployment complete!' -ForegroundColor Green
Write-Host 'Next steps:' -ForegroundColor Yellow
Write-Host '  1. Visit: https://storage-facility-creator.web.app or https://www.storagefacilitycreator.com' -ForegroundColor White
Write-Host '  2. Hard-refresh (Ctrl+Shift+R) if you still see the old version.' -ForegroundColor White
Write-Host '  3. To make the current marketing the live site at www.storagefacilitycreator.com, ensure the domain points to Firebase Hosting (see docs/MARKETING_AS_LIVE_SITE.md)' -ForegroundColor Cyan
Write-Host '  4. See docs/FACILITY_SCOPING_FIXES.md for testing checklist' -ForegroundColor Cyan
