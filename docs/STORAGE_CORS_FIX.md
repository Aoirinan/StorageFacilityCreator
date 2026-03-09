# Firebase Storage CORS Fix for Contract Signing

## Problem

Contract signing fails with CORS errors when uploading the signed PDF from `storagefacilitycreator.com`:

```
Access to XMLHttpRequest at 'https://firebasestorage.googleapis.com/...' from origin 'https://storagefacilitycreator.com' 
has been blocked by CORS policy: Response to preflight request doesn't pass access control check
```

## Solution

Apply CORS configuration to the Firebase Storage bucket to allow uploads from your custom domain.

## Steps

### 1. Install Google Cloud SDK (if not installed)

Download and install from: https://cloud.google.com/sdk/docs/install

### 2. Authenticate

```powershell
gcloud auth login
```

### 3. Apply CORS configuration

From the project root:

```powershell
.\apply-storage-cors.ps1
```

Or manually:

```powershell
gcloud storage buckets update gs://storage-facility-creator.appspot.com --cors-file=storage.cors.json
```

### 4. Verify

The CORS config allows requests from:
- https://storagefacilitycreator.com
- https://www.storagefacilitycreator.com
- https://storage-facility-creator.web.app
- https://storage-facility-creator.firebaseapp.com
- localhost (for development)

### Permissions

You need the **Storage Admin** role (`roles/storage.admin`) on the bucket. Project owners have this by default.
