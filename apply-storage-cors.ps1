# Apply CORS configuration to Firebase Storage bucket
# Required for contract signing uploads from storagefacilitycreator.com (custom domain)
# Run: .\apply-storage-cors.ps1
# Requires: gcloud CLI installed and authenticated (gcloud auth login)

$bucket = "storage-facility-creator.appspot.com"
$corsFile = "storage.cors.json"

Write-Host "Applying CORS config to gs://$bucket" -ForegroundColor Cyan
Write-Host "Using config from $corsFile" -ForegroundColor Cyan
Write-Host ""

# Check if gcloud is installed
$gcloud = Get-Command gcloud -ErrorAction SilentlyContinue
if (-not $gcloud) {
    Write-Host "ERROR: gcloud CLI not found. Install from: https://cloud.google.com/sdk/docs/install" -ForegroundColor Red
    exit 1
}

# Apply CORS
gcloud storage buckets update "gs://$bucket" --cors-file="$corsFile"
if ($LASTEXITCODE -ne 0) {
    Write-Host "CORS update failed. Ensure you have Storage Admin role and are authenticated." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "CORS applied successfully. Contract signing uploads from storagefacilitycreator.com should now work." -ForegroundColor Green
