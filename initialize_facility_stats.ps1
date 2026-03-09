# Initialize Facility Stats for All Facilities
# Run this ONCE after deploying the new Cloud Functions

Write-Host "🚀 Initializing facility stats..." -ForegroundColor Cyan

# This script triggers the manual stats update for all facilities
# Stats will be stored in facilities/{facilityId}/stats/current

Write-Host ""
Write-Host "OPTIONS TO INITIALIZE STATS:" -ForegroundColor Yellow
Write-Host ""
Write-Host "Option 1: Wait for Automatic Updates (RECOMMENDED)" -ForegroundColor Green
Write-Host "  - The onTenantWrite and onUnitWrite triggers will populate stats automatically"
Write-Host "  - Next time any tenant or unit is created/updated, stats will be computed"
Write-Host "  - Scheduled function will run at 2 AM ET to refresh all facilities"
Write-Host ""
Write-Host "Option 2: Manually Trigger Stats Update via Firebase Console" -ForegroundColor Green
Write-Host "  1. Go to: https://console.firebase.google.com/project/storage-facility-creator/functions"
Write-Host "  2. Find function: updateFacilityStatsManual"
Write-Host "  3. Click 'Test function'"
Write-Host "  4. Enter: { `"facilityId`": `"YOUR_FACILITY_ID`" }"
Write-Host "  5. Click 'Run the function'"
Write-Host "  6. Repeat for each facility"
Write-Host ""
Write-Host "Option 3: Use Firebase CLI (Advanced)" -ForegroundColor Green
Write-Host "  Run these commands for each facility ID:"
Write-Host "  firebase functions:call updateFacilityStatsManual --data '{`"facilityId`":`"FACILITY_ID_HERE`"}'"
Write-Host ""
Write-Host "Option 4: Create a Temporary One-Time Script (Bulk)" -ForegroundColor Green
Write-Host "  1. Copy this code into Firebase Console > Firestore > Query"
Write-Host "  2. Run as a Cloud Function or in Node.js environment"
Write-Host ""
Write-Host "  const admin = require('firebase-admin');"
Write-Host "  admin.initializeApp();"
Write-Host ""
Write-Host "  async function initAllStats() {"
Write-Host "    const db = admin.firestore();"
Write-Host "    const facilities = await db.collection('facilities').get();"
Write-Host "    "
Write-Host "    for (const facilityDoc of facilities.docs) {"
Write-Host "      const facilityId = facilityDoc.id;"
Write-Host "      console.log(\`Triggering stats for \${facilityId}...\`);"
Write-Host "      "
Write-Host "      try {"
Write-Host "        const result = await admin.functions().httpsCallable('updateFacilityStatsManual')({ facilityId });"
Write-Host "        console.log(\`✅ \${facilityId}: Success\`);"
Write-Host "      } catch (error) {"
Write-Host "        console.error(\`❌ \${facilityId}: \${error.message}\`);"
Write-Host "      }"
Write-Host "    }"
Write-Host "  }"
Write-Host ""
Write-Host "  initAllStats();"
Write-Host ""
Write-Host "✅ Deployment complete! Your fixes are now live." -ForegroundColor Green
Write-Host ""
Write-Host "🔍 VERIFY DEPLOYMENT:" -ForegroundColor Yellow
Write-Host "  1. Visit: https://storage-facility-creator.web.app"
Write-Host "  2. Navigate to Dashboard"
Write-Host "  3. Check that metrics show real data (may take a few minutes for stats to populate)"
Write-Host "  4. Navigate to Contracts - verify no double UI"
Write-Host "  5. Check sidebar - verify 'Stripe Connect' is removed"
Write-Host "  6. Check Insurance page - verify disclaimer is visible"
Write-Host ""
Write-Host "📊 MONITORING:" -ForegroundColor Yellow
Write-Host "  - View Cloud Functions logs: firebase functions:log --only onTenantWrite,onUnitWrite"
Write-Host "  - Check Firestore for stats docs: facilities/{facilityId}/stats/current"
Write-Host ""
Write-Host "📖 DOCUMENTATION:" -ForegroundColor Yellow
Write-Host "  - What changed: WHAT_CHANGED_SUMMARY.md"
Write-Host "  - Test checklist: PRODUCT_FIXES_SUMMARY.md"
Write-Host "  - Deployment guide: DEPLOYMENT_GUIDE.md"
Write-Host ""
