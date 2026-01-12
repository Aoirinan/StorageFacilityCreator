import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kReleaseMode, kIsWeb;
import 'dart:ui' show PlatformDispatcher;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:sfcapp/l10n/app_localizations.dart';
import 'firebase_options.dart';
import 'router/app_router.dart';
import 'providers/locale_provider.dart';
import 'services/security_service.dart';
import 'services/error_reporter.dart';
import 'services/debug_logger.dart';
import 'theme/app_theme.dart';
import 'test_firestore_rules.dart';
import 'widgets/error_banner.dart';
import 'config/firebase_emulator_config.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'services/app_check_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // #region agent log
  DebugLogger.log(
    hypothesisId: 'H0',
    location: 'main.dart:main',
    message: 'Main entry, WidgetsFlutterBinding.ensureInitialized complete',
  );
  // #endregion
  Future<void> startApp() async {
    // #region agent log
    DebugLogger.log(
      hypothesisId: 'H0',
      location: 'main.dart:startApp',
      message: 'Starting runApp',
    );
    // #endregion
    runApp(const ProviderScope(child: SFCApp()));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeBackgroundServices();
    });
  }
  
  // Catch and log any unhandled errors
  FlutterError.onError = (FlutterErrorDetails details) {
    if (kDebugMode) {
      FlutterError.presentError(details);
      print('❌ Flutter Error: ${details.exception}');
      print('Stack: ${details.stack}');
    }
    ErrorReporter.reportError(
      details.exception,
      details.stack,
      context: 'FlutterError.onError',
    );
  };
  
  // Catch platform errors (only suppress known noisy web focus issues)
  PlatformDispatcher.instance.onError = (error, stack) {
    final errorString = error.toString().toLowerCase();
    final isFocusNoise = errorString.contains('focus') ||
        errorString.contains('js_helper') ||
        stack.toString().contains('focus_manager') ||
        stack.toString().contains('focus_traversal');

    if (isFocusNoise) {
      if (kDebugMode) {
        print('⚠️ Focus error suppressed: $error');
      }
      ErrorReporter.reportInfo('Suppressed focus/platform noise: $error');
      return true; // Suppress only the known noisy errors
    }

    ErrorReporter.reportError(error, stack, context: 'PlatformDispatcher.onError');
    if (kDebugMode) {
      print('❌ Platform Error: $error');
      print('Stack: $stack');
    }
    return false; // Let Flutter decide (surfaces in debug, crash in release)
  };
  
  // Configure Firebase Emulators in debug mode (if USE_EMULATORS is set)
  // To use emulators, set environment variable: USE_EMULATORS=true
  // Or use: flutter run -d chrome --dart-define=USE_EMULATORS=true
  const useEmulators = bool.fromEnvironment('USE_EMULATORS', defaultValue: false);
  
  if (kDebugMode && useEmulators) {
    try {
      await configureFirebaseEmulators();
      if (kDebugMode) {
        print('🔧 Using Firebase Emulators for local development');
      }
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Failed to configure emulators: $e');
        print('   Continuing with production Firebase...');
      }
    }
  } else if (kDebugMode) {
    print('ℹ️ Using production Firebase (set USE_EMULATORS=true to use emulators)');
  }
  
  Future<void> bootstrapFirebaseAndApp() async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
      await _activateAppCheck();
    // #region agent log
    DebugLogger.log(
      hypothesisId: 'H1',
      location: 'main.dart:Firebase.initializeApp',
      message: 'Firebase init success',
    );
    // #endregion
    if (kDebugMode) {
      print('✅ Firebase initialized successfully');
    }
    if (kDebugMode) {
      print('🚀 Starting SFC App - Storage Facility Creator');
    }
    await startApp();
  } catch (e, stackTrace) {
    // #region agent log
    DebugLogger.log(
      hypothesisId: 'H1',
      location: 'main.dart:Firebase.initializeApp',
      message: 'Firebase init failure',
      data: {'error': e.toString()},
    );
    // #endregion
    ErrorReporter.reportError(e, stackTrace, context: 'Firebase.initializeApp');
    if (kDebugMode) {
      print('❌ Firebase initialization error: $e');
      print('Stack: $stackTrace');
    }
    _showFirebaseInitErrorUI(
      error: e,
      onRetry: () async {
        try {
          await Firebase.initializeApp(
            options: DefaultFirebaseOptions.currentPlatform,
          );
            await _activateAppCheck();
          if (kDebugMode) {
            print('✅ Firebase initialized successfully (retry)');
          }
          await startApp();
        } catch (retryError, retryStack) {
          ErrorReporter.reportError(retryError, retryStack, context: 'Firebase.initializeApp.retry');
          if (kDebugMode) {
            print('❌ Firebase retry failed: $retryError');
            print('Stack: $retryStack');
          }
        }
      },
    );
    }
  }

  final enableSentry = const bool.fromEnvironment('ENABLE_SENTRY', defaultValue: false);
  final sentryDsn = const String.fromEnvironment('SENTRY_DSN', defaultValue: '');

  if (enableSentry && sentryDsn.isNotEmpty) {
    await SentryFlutter.init(
      (options) {
        options.dsn = sentryDsn;
        options.tracesSampleRate = 0.15;
        options.enableAppLifecycleBreadcrumbs = true;
      },
      appRunner: () async {
        ErrorReporter.enableSentry();
        await bootstrapFirebaseAndApp();
      },
    );
  } else {
    await bootstrapFirebaseAndApp();
  }
}

void _initializeBackgroundServices() {
  // Initialize security service only in production to avoid development connectivity issues
  if (kReleaseMode) {
    // Get account ID from auth or use default
    final accountId = FirebaseAuth.instance.currentUser?.uid ?? 'default';
    SecurityService.initializeDefaultSettings(accountId).catchError((error) {
      if (kDebugMode) {
        print('❌ Error initializing default security settings: $error');
      }
    });
  } else {
    if (kDebugMode) {
      print('⚠️ Development mode: Skipping security service initialization');
    }
  }
  
  // Test Firestore rules in debug mode only (non-blocking)
  if (kDebugMode) {
    Future.delayed(const Duration(seconds: 2), () {
      FirestoreRulesTester.testUserDocumentCreation();
    });
  }
}

Future<void> _activateAppCheck() async {
  // App Check activation with environment-based provider selection
  // Production: reCAPTCHA v3 (requires APPCHECK_SITE_KEY)
  // Development: Debug provider (automatic for localhost)
  // Toggle via dart-define: --dart-define=ENABLE_APPCHECK=true --dart-define=APPCHECK_SITE_KEY=<key>
  const enableAppCheck = bool.fromEnvironment('ENABLE_APPCHECK', defaultValue: false);
  String webSiteKey = const String.fromEnvironment('APPCHECK_SITE_KEY', defaultValue: '');

  // Auto-enable App Check for production domain if not explicitly disabled
  // Production site key: 6LdfgkYsAAAAACukbDsZuvURRCPqcioby-bm3adD
  // Site keys are public and safe to include in client code
  bool shouldActivate = enableAppCheck;
  
  // Always log for visibility (not just debug mode)
  print('🔍 [AppCheck] Initialization check: enableAppCheck=$enableAppCheck, kIsWeb=$kIsWeb, webSiteKey=${webSiteKey.isNotEmpty ? "SET" : "EMPTY"}');
  
  if (!enableAppCheck && kIsWeb) {
    // Auto-enable App Check for all web builds (production site key)
    // This ensures App Check is always enabled for production deployments
    print('🔧 [AppCheck] Auto-enabling App Check with production site key');
    webSiteKey = '6LdfgkYsAAAAACukbDsZuvURRCPqcioby-bm3adD';
    shouldActivate = true; // Force activation if we have a site key
  }

  // If still no site key after auto-detection, skip App Check
  if (!shouldActivate || webSiteKey.isEmpty) {
    print('⚠️ [AppCheck] Skipping activation - shouldActivate=$shouldActivate, webSiteKey.isEmpty=${webSiteKey.isEmpty}');
    return;
  }
  
  print('✅ [AppCheck] Proceeding with activation - site key: ${webSiteKey.substring(0, 8)}...');

  try {
    // Use centralized AppCheckService
    print('🚀 [AppCheck] Calling AppCheckService.activate with forceEnable=$shouldActivate');
    await AppCheckService.activate(
      webSiteKey: webSiteKey.isNotEmpty ? webSiteKey : null,
      forceEnable: shouldActivate,
    );
    
    // Always log activation status (not just in debug mode)
    if (AppCheckService.isActivated) {
      final stats = AppCheckService.getMonitoringStats();
      print('✅ [AppCheck] Activation successful! Stats: $stats');
    } else {
      print('⚠️ [AppCheck] Activation completed but isActivated=false');
    }
  } catch (e, stack) {
    // Error already logged by AppCheckService, but log here too for visibility
    print('❌ [AppCheck] Activation failed: $e');
    print('   Stack: $stack');
    ErrorReporter.reportError(e, stack, context: 'AppCheck.activate');
    print('⚠️ [AppCheck] App will continue but App Check protected calls may fail');
    // Don't rethrow - allow app to continue
  }
}

void _showFirebaseInitErrorUI({
  required Object error,
  required Future<void> Function() onRetry,
}) {
  // #region agent log
  DebugLogger.log(
    hypothesisId: 'H1',
    location: 'main.dart:_showFirebaseInitErrorUI',
    message: 'Showing Firebase init error UI',
    data: {'error': error.toString()},
  );
  // #endregion
  runApp(MaterialApp(
    home: Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24.0),
              child: Text(
                'Startup error: Firebase failed to initialize.',
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 8),
            if (kDebugMode)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Text(
                  error.toString(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () {
                onRetry();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    ),
  ));
}

class SFCApp extends ConsumerWidget {
  const SFCApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(goRouterProvider);
    final locale = ref.watch(localeProvider);

    return MaterialApp.router(
      title: 'SFC App - Storage Facility Creator',
      theme: AppTheme.lightTheme,
      routerConfig: router,
      builder: (context, child) => ScrollConfiguration(
        behavior: const _AppScrollBehavior(),
        child: ErrorBanner(
          child: child ?? const SizedBox.shrink(),
        ),
      ),
      scrollBehavior: const _AppScrollBehavior(),
      debugShowCheckedModeBanner: false,
      locale: locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en', 'US'),
        Locale('es', 'ES'),
        Locale('fr', 'FR'),
        Locale('de', 'DE'),
        Locale('zh', 'CN'),
        Locale('ja', 'JP'),
      ],
    );
  }
}

class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };
}

