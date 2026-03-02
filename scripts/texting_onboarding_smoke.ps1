param(
  [Parameter(Mandatory=$true)] [string] $ProjectId,
  [Parameter(Mandatory=$true)] [string] $WebApiKey,
  [Parameter(Mandatory=$true)] [string] $Email,
  [Parameter(Mandatory=$true)] [string] $Password,
  [Parameter(Mandatory=$true)] [string] $FacilityId,
  [string] $Region = "us-central1"
)

function Invoke-Callable($name, $idToken, $payload) {
  $url = "https://$Region-$ProjectId.cloudfunctions.net/$name"
  return Invoke-RestMethod -Method Post -Uri $url -Headers @{
    "Authorization" = "Bearer $idToken"
    "Content-Type" = "application/json"
  } -Body (@{ data = $payload } | ConvertTo-Json -Depth 10)
}

Write-Host "Logging in test user..."
$authResp = Invoke-RestMethod -Method Post -Uri "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=$WebApiKey" -ContentType "application/json" -Body (@{
  email = $Email
  password = $Password
  returnSecureToken = $true
} | ConvertTo-Json)

$idToken = $authResp.idToken
if (-not $idToken) {
  throw "Failed to obtain Firebase ID token."
}

Write-Host "1) Save business info..."
Invoke-Callable "saveTextingBusinessInfo" $idToken @{
  facilityId = $FacilityId
  businessData = @{
    legalBusinessName = "Smoke Test Storage LLC"
    businessType = "LLC"
    ein = "12-3456789"
    addressLine1 = "123 Test St"
    city = "Austin"
    state = "TX"
    postalCode = "78701"
    website = "https://example.com"
    supportEmail = "support@example.com"
    supportPhone = "+15125550123"
  }
} | Out-Null

Write-Host "2) Provision number..."
$provision = Invoke-Callable "provisionPhoneNumber" $idToken @{
  facilityId = $FacilityId
  areaCode = "512"
}
Write-Host ("Provision result: " + ($provision | ConvertTo-Json -Depth 6))

Write-Host "3) Submit onboarding..."
$submit = Invoke-Callable "submitTextingOnboarding" $idToken @{
  facilityId = $FacilityId
  campaignData = @{
    useCases = @("Late notices", "Payment reminders")
    sampleMessages = @(
      "Your payment is due. Reply STOP to opt out.",
      "Past due notice: please pay now. Reply STOP to opt out."
    )
    consentConfirmed = $true
  }
}
Write-Host ("Submit result: " + ($submit | ConvertTo-Json -Depth 6))

Write-Host "4) Refresh status..."
$status = Invoke-Callable "refreshTextingOnboardingStatus" $idToken @{
  facilityId = $FacilityId
}
Write-Host ("Status result: " + ($status | ConvertTo-Json -Depth 6))

Write-Host "Smoke test complete."
