import * as functions from 'firebase-functions/v1';

export const redirectToCustomDomain = functions.https.onRequest((req, res) => {
  // Use x-forwarded-host as Firebase Hosting proxies requests
  const forwardedHost = req.get('x-forwarded-host') || req.get('host') || '';
  const canonicalDomain = 'www.storagefacilitycreator.com';

  // Check if the request is coming from a Firebase default domain
  const isFirebaseDomain =
    forwardedHost.includes('.web.app') ||
    forwardedHost.includes('.firebaseapp.com');

  if (isFirebaseDomain) {
    // Redirect to the custom domain, preserving the path and query string
    const path = req.path;
    const query = req.url.includes('?') ? req.url.substring(req.url.indexOf('?')) : '';
    const redirectUrl = `https://${canonicalDomain}${path}${query}`;

    res.redirect(301, redirectUrl);
    return;
  }

  // For custom domain: Since static files take precedence in Firebase Hosting,
  // this function is only called for paths that don't match static files.
  // For those paths, we should serve index.html. However, we can't easily
  // read it from the function.
  //
  // For custom domain: Serve index.html content for SPA routing
  // Static files (JS, CSS, etc.) are served directly by Firebase Hosting
  // This function is only called for paths that don't match static files
  const indexHtml = `<!DOCTYPE html>
<html>
<head>
  <base href="/">
  <meta charset="UTF-8">
  <meta content="IE=Edge" http-equiv="X-UA-Compatible">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes, viewport-fit=cover">
  <meta name="description" content="Storage Facility Creator - Manage your storage facilities with ease">
  <meta name="mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="default">
  <meta name="apple-mobile-web-app-title" content="SFC App">
  <meta name="apple-touch-fullscreen" content="yes">
  <meta name="format-detection" content="telephone=no">
  <meta http-equiv="Content-Security-Policy" content="upgrade-insecure-requests">
  <link rel="apple-touch-icon" href="/icons/Icon-192.png">
  <link rel="icon" type="image/png" href="/favicon.png"/>
  <title>SFC App - Storage Facility Creator</title>
  <link rel="canonical" href="https://www.storagefacilitycreator.com">
  <script src="https://js.stripe.com/v3/"></script>
  <meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate, max-age=0, private">
  <meta http-equiv="Pragma" content="no-cache">
  <meta http-equiv="Expires" content="0">
</head>
<body>
  <script>
    (function() {
      'use strict';
      window.addEventListener('error', function(event) {
        const errorMsg = event.error?.message || event.error?.toString() || '';
        const errorStack = event.error?.stack || '';
        if (errorMsg.includes('focus') || errorMsg.includes('Focus') || errorMsg.includes('js_helper') ||
            errorStack.includes('focus_manager') || errorStack.includes('focus_traversal') || errorStack.includes('js_helper')) {
          console.warn('⚠️ Focus error caught and suppressed:', errorMsg);
          event.preventDefault();
          return true;
        }
        if (errorMsg.includes('BloomFilter') || errorMsg.includes('BloomFilterError') ||
            errorStack.includes('BloomFilter') || errorStack.includes('BloomFilterError')) {
          event.preventDefault();
          return true;
        }
        console.error('❌ Uncaught error:', event.error);
        return false;
      });
      window.addEventListener('unhandledrejection', function(event) {
        const reason = event.reason?.toString() || '';
        if (reason.includes('BloomFilter') || reason.includes('BloomFilterError')) {
          event.preventDefault();
          return;
        }
        console.warn('⚠️ Unhandled promise rejection:', event.reason);
        event.preventDefault();
      });
    })();
  </script>
  <script src="/flutter_bootstrap.js" async></script>
</body>
</html>`;

  res.set('Content-Type', 'text/html');
  res.set('Cache-Control', 'no-cache, no-store, must-revalidate');
  res.status(200).send(indexHtml);
});
