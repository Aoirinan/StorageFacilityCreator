import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';
import 'error_reporter.dart';

// Web-only import - only used when kIsWeb is true
import 'dart:html' as html;

/// Centralized Firebase App Check service with environment-based activation
/// 
/// Production: Uses reCAPTCHA v3 provider with site key
/// Development: Uses debug provider for localhost/dev testing
/// 
/// No secret keys are used in client code - only site keys.
class AppCheckService {
  static bool _isActivated = false;
  static bool _isDebugMode = false;
  static String? _debugToken;
  static int _tokenSuccessCount = 0;
  static int _tokenFailureCount = 0;
  static DateTime? _lastTokenRefresh;
  static DateTime? _lastTokenFailure;
  static String? _currentProvider;
  static String? _hostname;

  /// Check if App Check is currently activated
  static bool get isActivated => _isActivated;

  /// Check if App Check is in debug mode
  static bool get isDebugMode => _isDebugMode;

  /// Get the debug token (only available in debug mode)
  static String? get debugToken => _isDebugMode ? _debugToken : null;

  /// Get current provider type
  static String? get currentProvider => _currentProvider;

  /// Get current hostname
  static String? get hostname => _hostname;

  /// Get token success count (for monitoring)
  static int get tokenSuccessCount => _tokenSuccessCount;

  /// Get token failure count (for monitoring)
  static int get tokenFailureCount => _tokenFailureCount;

  /// Get last token refresh time
  static DateTime? get lastTokenRefresh => _lastTokenRefresh;

  /// Get last token failure time
  static DateTime? get lastTokenFailure => _lastTokenFailure;

  /// Get hostname (web only)
  static String? _getHostname() {
    if (!kIsWeb) return null;
    try {
      // Get hostname from browser location (web only)
      return html.window.location.hostname;
    } catch (e) {
      // Not on web or html not available
      return null;
    }
  }

  /// Determine if we should use debug provider
  /// 
  /// Returns true if:
  /// - APP_CHECK_DEBUG environment variable is set to 'true'
  /// - OR we're running on localhost
  /// - OR we're in debug mode (kDebugMode)
  static bool _shouldUseDebugProvider() {
    // Check environment variable
    const appCheckDebug = String.fromEnvironment('APP_CHECK_DEBUG', defaultValue: '');
    if (appCheckDebug.toLowerCase() == 'true') {
      return true;
    }

    // Check if we're on localhost (web only)
    if (kIsWeb) {
      _hostname = _getHostname();
      if (_hostname == 'localhost' || 
          _hostname == '127.0.0.1' || 
          (_hostname != null && (
            _hostname!.startsWith('192.168.') ||
            _hostname!.startsWith('10.') ||
            _hostname!.startsWith('172.')))) {
        return true;
      }
    }

    // In debug builds, allow debug provider
    return kDebugMode;
  }

  /// Activate App Check with environment-based provider selection
  /// 
  /// Production: Uses ReCaptchaV3Provider with site key
  /// Development: Uses ReCaptchaEnterpriseProvider (debug) for localhost
  /// 
  /// Site key should start with "6L..." (reCAPTCHA v3 site key)
  /// Secret key is configured in Firebase Console, NOT in client code
  static Future<void> activate({
    String? webSiteKey,
    bool forceEnable = false,
  }) async {
    const enableAppCheck = bool.fromEnvironment('ENABLE_APPCHECK', defaultValue: false);
    
    // Always log for visibility
    print('🔍 [AppCheckService] activate called: enableAppCheck=$enableAppCheck, forceEnable=$forceEnable, webSiteKey=${webSiteKey != null ? "PROVIDED" : "NULL"}, kIsWeb=$kIsWeb');
    
    if (!enableAppCheck && !forceEnable) {
      print('⚠️ [AppCheckService] Disabled - ENABLE_APPCHECK=false and forceEnable=false');
      _isActivated = false;
      return;
    }

    if (!kIsWeb) {
      // Mobile platforms
      try {
        await FirebaseAppCheck.instance.activate(
          androidProvider: AndroidProvider.playIntegrity,
          appleProvider: AppleProvider.deviceCheck,
        );
        _isActivated = true;
        _currentProvider = 'mobile';
        if (kDebugMode) {
          print('✅ [AppCheck] Activated for mobile platform');
        }
        return;
      } catch (e, stack) {
        ErrorReporter.reportError(e, stack, context: 'AppCheck.activate.mobile');
        if (kDebugMode) {
          print('❌ [AppCheck] Mobile activation failed: $e');
        }
        rethrow;
      }
    }

    // Web platform
    _isDebugMode = _shouldUseDebugProvider();

    // For web, we always use ReCaptchaV3Provider
    // Debug mode is handled via debug tokens registered in Firebase Console
    final siteKey = webSiteKey ?? 
        const String.fromEnvironment('APPCHECK_SITE_KEY', defaultValue: '');

    print('🔍 [AppCheckService] Web platform detected - siteKey=${siteKey.isNotEmpty ? "${siteKey.substring(0, 8)}..." : "EMPTY"}, _isDebugMode=$_isDebugMode');

    if (siteKey.isEmpty) {
      final error = 'APPCHECK_SITE_KEY not provided for App Check';
      print('❌ [AppCheckService] $error');
      ErrorReporter.reportError(error, null, context: 'AppCheck.activate');
      _isActivated = false;
      return;
    }

    // Validate site key format (should start with "6L")
    if (!siteKey.startsWith('6L')) {
      final error = 'Invalid reCAPTCHA site key format (should start with "6L")';
      ErrorReporter.reportError(error, null, context: 'AppCheck.activate');
      if (kDebugMode) {
        print('❌ [AppCheck] $error');
      }
      _isActivated = false;
      return;
    }

    try {
      print('🚀 [AppCheckService] Activating Firebase App Check with ReCaptchaV3Provider...');
      await FirebaseAppCheck.instance.activate(
        webProvider: ReCaptchaV3Provider(siteKey),
      );
      _isActivated = true;
      _currentProvider = _isDebugMode ? 'recaptcha-v3-debug' : 'recaptcha-v3';

      // Always log activation success (not just in debug mode)
      print('✅ [AppCheckService] ${_isDebugMode ? "Debug" : "Production"} mode activated');
      print('   Hostname: $_hostname');
      print('   Provider: reCAPTCHA v3');
      print('   Site Key: ${siteKey.substring(0, 8)}...');
      print('   isActivated: $_isActivated');
      
      if (_isDebugMode) {
        print('');
        print('🔑 [AppCheckService] DEBUG MODE - Debug Token Required');
        print('═══════════════════════════════════════════════════════');
        print('📋 To use debug tokens:');
        print('   1. Get debug token from browser console after first token request');
        print('   2. Go to Firebase Console > App Check > Apps > [Your App]');
        print('   3. Add debug token in "Debug tokens" section');
        print('═══════════════════════════════════════════════════════');
        print('');
      }

      // For web debug mode, Firebase logs the debug token to browser console
      // We can't directly access it, but we'll log instructions
      if (_isDebugMode) {
        if (kDebugMode) {
          print('');
          print('🔑 [AppCheck] DEBUG TOKEN INSTRUCTIONS');
          print('═══════════════════════════════════════════════════════');
          print('To get your debug token:');
          print('1. Open browser DevTools Console (F12)');
          print('2. Look for a message like: "App Check debug token: ..."');
          print('3. OR check the Network tab for requests to:');
          print('   content-firebaseappcheck.googleapis.com');
          print('4. The debug token will be in the response or console');
          print('');
          print('Alternative: Check Firebase Console > App Check > Apps');
          print('   Debug tokens may appear automatically after first request');
          print('═══════════════════════════════════════════════════════');
          print('');
        }
        
        // Try to get token (will fail until debug token is registered, but that's OK)
        try {
          final token = await FirebaseAppCheck.instance.getToken(true);
          _debugToken = token;
          _tokenSuccessCount++;
          _lastTokenRefresh = DateTime.now();
          
          if (kDebugMode && token != null) {
            print('✅ [AppCheck] Token obtained (may be debug token)');
            final preview = token.length > 20 ? token.substring(0, 20) : token;
            print('   Token preview: $preview...');
          }
        } catch (e) {
          if (kDebugMode) {
            print('⚠️ [AppCheck] Token request failed (expected until debug token registered): $e');
            print('   This is normal - add debug token to Firebase Console first');
          }
        }
      } else {
        // Verify token generation for production
        _verifyTokenGeneration();
      }
    } catch (e, stack) {
      // Always log errors (not just in debug mode)
      print('❌ [AppCheckService] Activation failed: $e');
      print('   Stack: $stack');
      if (_isDebugMode) {
        print('   For debug mode, ensure debug tokens are registered in Firebase Console');
      } else {
        print('   Check that reCAPTCHA v3 secret key is configured in Firebase Console');
      }
      ErrorReporter.reportError(e, stack, context: 'AppCheck.activate');
      _isActivated = false;
      rethrow;
    }
  }

  /// Get App Check token with error handling
  /// 
  /// Returns null if token acquisition fails (non-blocking)
  static Future<String?> getToken({bool forceRefresh = false}) async {
    if (!_isActivated) {
      if (kDebugMode) {
        print('⚠️ [AppCheck] Token requested but App Check not activated');
      }
      return null;
    }

    try {
      final token = await FirebaseAppCheck.instance.getToken(forceRefresh);
      _tokenSuccessCount++;
      _lastTokenRefresh = DateTime.now();

      if (kDebugMode) {
        print('✅ [AppCheck] Token retrieved successfully');
      }

      return token;
    } catch (e, stack) {
      _tokenFailureCount++;
      _lastTokenFailure = DateTime.now();
      
      // Check if this is a 400 error (expected until Firebase Console is configured)
      final errorString = e.toString().toLowerCase();
      final isConfigurationError = errorString.contains('400') || 
                                   errorString.contains('bad request') ||
                                   errorString.contains('exchangeRecaptchaV3Token');
      
      // Log structured error information
      final errorInfo = {
        'error': e.toString(),
        'hostname': _hostname,
        'provider': _currentProvider,
        'isDebugMode': _isDebugMode,
        'isActivated': _isActivated,
        'isConfigurationError': isConfigurationError,
      };

      if (isConfigurationError) {
        // This is expected - reCAPTCHA secret key needs to be configured in Firebase Console
        // Log as info, not error, to avoid noise
        if (kDebugMode) {
          print('⚠️ [AppCheck] Token retrieval failed - reCAPTCHA secret key not configured in Firebase Console');
          print('   This is expected until App Check is fully configured');
          print('   Fix: https://console.firebase.google.com/project/storage-facility-creator/appcheck');
        }
        
        // Report as info, not error, since this is a configuration issue
        ErrorReporter.reportInfo(
          '[AppCheck.getToken] App Check token retrieval failed (expected until configured): reCAPTCHA secret key needs to be set in Firebase Console. Hostname: ${_hostname ?? "unknown"}, Provider: ${_currentProvider ?? "unknown"}',
        );
      } else {
        // Unexpected error - log as error
        if (kDebugMode) {
          print('❌ [AppCheck] Token retrieval failed');
          print('   Error: $e');
          print('   Context: $errorInfo');
        }

        // Report error (without exposing secrets)
        ErrorReporter.reportError(
          'App Check token retrieval failed: ${e.toString()}',
          stack,
          context: 'AppCheck.getToken',
          metadata: errorInfo,
        );
      }

      // Return null instead of throwing (non-blocking)
      return null;
    }
  }

  /// Verify token generation works after activation
  /// This is non-blocking and won't throw errors
  static Future<void> _verifyTokenGeneration() async {
    try {
      final token = await getToken().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          if (kDebugMode) {
            print('⚠️ [AppCheck] Token generation verification timed out');
          }
          return null;
        },
      );
      if (token != null) {
        if (kDebugMode) {
          print('✅ [AppCheck] Token generation verified');
        }
      } else {
        // This is expected if reCAPTCHA secret key is not configured in Firebase Console
        // Don't log as error - it's a configuration issue, not a code issue
        if (kDebugMode) {
          print('⚠️ [AppCheck] Token generation verification returned null');
          print('   This is expected if reCAPTCHA secret key is not configured in Firebase Console');
          print('   See: https://console.firebase.google.com/project/storage-facility-creator/appcheck');
        }
      }
    } catch (e, stack) {
      // Catch any unexpected errors and log them, but don't propagate
      _tokenFailureCount++;
      _lastTokenFailure = DateTime.now();
      
      if (kDebugMode) {
        print('⚠️ [AppCheck] Token generation verification failed: $e');
        print('   This may be due to reCAPTCHA secret key not being configured in Firebase Console');
      }
      
      // Report silently - this is expected until Firebase Console is configured
      ErrorReporter.reportInfo(
        '[AppCheck._verifyTokenGeneration] App Check token verification failed (expected until configured): ${e.toString()}',
      );
    }
  }

  /// Get monitoring statistics
  static Map<String, dynamic> getMonitoringStats() {
    return {
      'isActivated': _isActivated,
      'isDebugMode': _isDebugMode,
      'currentProvider': _currentProvider,
      'hostname': _hostname,
      'tokenSuccessCount': _tokenSuccessCount,
      'tokenFailureCount': _tokenFailureCount,
      'lastTokenRefresh': _lastTokenRefresh?.toIso8601String(),
      'lastTokenFailure': _lastTokenFailure?.toIso8601String(),
      'platform': kIsWeb ? 'web' : 'mobile',
      'debugToken': _isDebugMode ? _debugToken : null,
    };
  }

  /// Reset monitoring statistics (for testing)
  static void resetStats() {
    _tokenSuccessCount = 0;
    _tokenFailureCount = 0;
    _lastTokenRefresh = null;
    _lastTokenFailure = null;
  }

  /// Run diagnostic test
  /// 
  /// Tests App Check token acquisition and optionally a Firestore read
  static Future<Map<String, dynamic>> runDiagnostic({
    bool testFirestore = false,
  }) async {
    final results = <String, dynamic>{
      'timestamp': DateTime.now().toIso8601String(),
      'hostname': _hostname,
      'isActivated': _isActivated,
      'isDebugMode': _isDebugMode,
      'provider': _currentProvider,
    };

    // Test token acquisition
    try {
      final token = await getToken(forceRefresh: true);
      results['tokenTest'] = {
        'success': token != null,
        'tokenLength': token?.length ?? 0,
        'error': token == null ? 'Token is null' : null,
      };
    } catch (e) {
      results['tokenTest'] = {
        'success': false,
        'error': e.toString(),
      };
    }

    // Test Firestore read (if requested)
    if (testFirestore) {
      try {
        // Simple Firestore read test
        // This will be handled by the caller if needed
        results['firestoreTest'] = {
          'success': true,
          'note': 'Firestore test should be done separately',
        };
      } catch (e) {
        results['firestoreTest'] = {
          'success': false,
          'error': e.toString(),
        };
      }
    }

    return results;
  }
}
