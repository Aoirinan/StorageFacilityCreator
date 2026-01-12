# PowerShell script to set Firebase Functions secrets
# Run this after you've obtained all your API keys

Write-Host "🔐 Setting up Firebase Functions secrets..." -ForegroundColor Cyan
Write-Host ""

# Check if Firebase CLI is installed
if (-not (Get-Command firebase -ErrorAction SilentlyContinue)) {
    Write-Host "❌ Firebase CLI not found. Please install it first:" -ForegroundColor Red
    Write-Host "   npm install -g firebase-tools" -ForegroundColor Yellow
    exit 1
}

# Check if logged in to Firebase
Write-Host "Checking Firebase login status..." -ForegroundColor Yellow
$firebaseUser = firebase login:list 2>&1
if ($firebaseUser -match "No authorized accounts") {
    Write-Host "❌ Not logged in to Firebase. Please run: firebase login" -ForegroundColor Red
    exit 1
}

Write-Host "✅ Firebase CLI ready" -ForegroundColor Green
Write-Host ""

# Change to functions directory
Set-Location functions

Write-Host "📝 You'll be prompted to enter each secret value." -ForegroundColor Cyan
Write-Host "   (You can paste the values when prompted)" -ForegroundColor Gray
Write-Host ""

# SendGrid secrets
Write-Host "📧 SendGrid Configuration" -ForegroundColor Cyan
firebase functions:secrets:set SENDGRID_API_KEY
firebase functions:secrets:set SENDGRID_FROM_EMAIL
firebase functions:secrets:set SENDGRID_FROM_NAME

Write-Host ""

# Twilio secrets
Write-Host "📱 Twilio Configuration" -ForegroundColor Cyan
firebase functions:secrets:set TWILIO_ACCOUNT_SID
firebase functions:secrets:set TWILIO_AUTH_TOKEN
firebase functions:secrets:set TWILIO_PHONE_NUMBER

Write-Host ""

# Stripe Platform secrets
Write-Host "💳 Stripe Platform Configuration" -ForegroundColor Cyan
firebase functions:secrets:set STRIPE_PUBLISHABLE_KEY
firebase functions:secrets:set STRIPE_SECRET_KEY
firebase functions:secrets:set STRIPE_WEBHOOK_SECRET

Write-Host ""

# Stripe Connect secrets
Write-Host "🔗 Stripe Connect Configuration" -ForegroundColor Cyan
firebase functions:secrets:set STRIPE_CONNECT_CLIENT_ID

Write-Host ""
Write-Host "✅ All secrets configured!" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "1. Deploy functions: firebase deploy --only functions" -ForegroundColor Yellow
Write-Host "2. Test email/SMS sending from the app" -ForegroundColor Yellow
Write-Host "3. Set up Stripe webhook endpoint (I'll help with this)" -ForegroundColor Yellow

