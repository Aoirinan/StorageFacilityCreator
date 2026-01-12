// Aggressive service worker and cache clearing
// This script runs before Flutter loads to ensure old code is cleared

(function() {
  'use strict';
  
  console.log('🧹 Clearing service workers and caches...');
  
  // Unregister all service workers
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.getRegistrations().then(function(registrations) {
      for(let registration of registrations) {
        registration.unregister().then(function(success) {
          console.log('✅ Service worker unregistered:', success);
        }).catch(function(error) {
          console.log('❌ Error unregistering service worker:', error);
        });
      }
    });
  }
  
  // Clear all caches
  if ('caches' in window) {
    caches.keys().then(function(names) {
      for (let name of names) {
        caches.delete(name).then(function(success) {
          console.log('✅ Cache deleted:', name, success);
        });
      }
    });
  }
  
  // Force reload if page is already loaded
  if (document.readyState === 'complete') {
    console.log('🔄 Page already loaded, forcing reload...');
    setTimeout(function() {
      window.location.reload(true);
    }, 100);
  }
})();
