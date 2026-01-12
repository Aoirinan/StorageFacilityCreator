// Service worker and cache clearing for web-only mode
// This script runs early in <head> to unregister any existing service workers
// and clear caches to prevent PWA installability

(function() {
  'use strict';
  
  // Prevent multiple executions
  if (window._sw_clear_executed) {
    return;
  }
  window._sw_clear_executed = true;
  
  console.log('🧹 [PWA Disable] Clearing service workers and caches for web-only mode...');
  
  // Unregister all service workers
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.getRegistrations().then(function(registrations) {
      if (registrations.length === 0) {
        console.log('✅ [PWA Disable] No service workers found');
        return;
      }
      
      console.log('🔧 [PWA Disable] Found ' + registrations.length + ' service worker(s) - unregistering...');
      const promises = registrations.map(function(registration) {
        return registration.unregister().then(function(success) {
          if (success) {
            console.log('✅ [PWA Disable] Service worker unregistered successfully');
          } else {
            console.warn('⚠️ [PWA Disable] Service worker unregistration returned false');
          }
          return success;
        }).catch(function(error) {
          console.error('❌ [PWA Disable] Error unregistering service worker:', error);
          return false;
        });
      });
      
      return Promise.all(promises).then(function(results) {
        const successCount = results.filter(function(r) { return r === true; }).length;
        console.log('✅ [PWA Disable] Unregistered ' + successCount + ' of ' + registrations.length + ' service worker(s)');
      });
    }).catch(function(error) {
      console.error('❌ [PWA Disable] Error getting service worker registrations:', error);
    });
  }
  
  // Clear all caches (CacheStorage API)
  if ('caches' in window) {
    caches.keys().then(function(names) {
      if (names.length === 0) {
        console.log('✅ [PWA Disable] No caches found');
        return;
      }
      
      console.log('🔧 [PWA Disable] Found ' + names.length + ' cache(s) - deleting...');
      const promises = names.map(function(name) {
        return caches.delete(name).then(function(success) {
          if (success) {
            console.log('✅ [PWA Disable] Cache deleted: ' + name);
          } else {
            console.warn('⚠️ [PWA Disable] Cache deletion returned false: ' + name);
          }
          return success;
        }).catch(function(error) {
          console.error('❌ [PWA Disable] Error deleting cache ' + name + ':', error);
          return false;
        });
      });
      
      return Promise.all(promises).then(function(results) {
        const successCount = results.filter(function(r) { return r === true; }).length;
        console.log('✅ [PWA Disable] Deleted ' + successCount + ' of ' + names.length + ' cache(s)');
      });
    }).catch(function(error) {
      console.error('❌ [PWA Disable] Error getting cache names:', error);
    });
  }
  
  // Note: We do NOT force a reload here to avoid infinite reload loops
  // The inline script in index.html will handle Flutter service worker disabling
  console.log('✅ [PWA Disable] Service worker cleanup script completed');
})();
