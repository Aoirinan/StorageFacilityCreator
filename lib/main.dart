import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kReleaseMode, kIsWeb;
import 'dart:ui' show PlatformDispatcher;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
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
import 'providers/theme_mode_provider.dart';
import 'test_firestore_rules.dart';
import 'widgets/error_banner.dart';
import 'config/firebase_emulator_config.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'config/app_check_public.dart';
import 'services/app_check_service.dart';
import 'services/quickbooks_oauth_handoff_stub.dart'
    if (dart.library.html) 'services/quickbooks_oauth_handoff_web.dart'
    as quickbooks_oauth_handoff;

// Static flag to ensure App Check is activated exactly once (DEPRECATED - use AppCheckService.isActivated instead)
bool _appCheckActivated = false;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    // Preserve Intuit OAuth payload even if auth guards redirect before Accounting loads.
    quickbooks_oauth_handoff.captureQuickBooksOAuthFromCurrentUrl();
  }
  // #region agent log
  DebugLogger.log(
    hypothesisId: 'H0',
    location: 'main.dart:main',
    message: 'Main entry, WidgetsFlutterBinding.ensureInitialized complete',
  );
  // #endregion
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
  
  /// Activate Firebase App Check exactly once
  /// 
  /// Uses AppCheckService.activate() which has built-in guards against double initialization
  Future<void> _activateAppCheckOnce() async {
    // Double-check: if AppCheckService is already activated, skip (prevents duplicate activation)
    if (AppCheckService.isActivated || _appCheckActivated) {
      if (kDebugMode) {
        print('⚠️ App Check already activated (AppCheckService.isActivated=${AppCheckService.isActivated}, _appCheckActivated=$_appCheckActivated), skipping duplicate activation');
      }
      return;
    }

    try {
      // Use the centralized AppCheckService to keep web + debug behavior consistent.
      // AppCheckService.activate() has its own guard against duplicate initialization
      await AppCheckService.activate(
        webSiteKey: kAppCheckRecaptchaSiteKey,
        forceEnable: true,
      );
      _appCheckActivated = true; // Also set local flag for backward compatibility
      if (kDebugMode) {
        print('✅ Firebase App Check activated with reCAPTCHA v3');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Failed to activate App Check: $e');
      }
      // Don't set _appCheckActivated = true on error, so retry can work
      rethrow;
    }
  }
  
  Future<void> bootstrapFirebaseAndApp() async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    // Disable Firestore persistence on web to avoid INTERNAL ASSERTION FAILED / listener state issues (apply once only)
    if (kIsWeb) {
      FirebaseFirestore.instance.settings = const Settings(persistenceEnabled: false);
    }

    await _activateAppCheckOnce();
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
    // #region agent log
    DebugLogger.log(
      hypothesisId: 'H0',
      location: 'main.dart:runApp',
      message: 'Starting runApp',
    );
    // #endregion
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeBackgroundServices();
    });
    runApp(const ProviderScope(child: SFCApp()));
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

          await _activateAppCheckOnce();

          if (kDebugMode) {
            print('✅ Firebase initialized successfully (retry)');
          }
          // #region agent log
          DebugLogger.log(
            hypothesisId: 'H0',
            location: 'main.dart:runApp.retry',
            message: 'Starting runApp (retry)',
          );
          // #endregion
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _initializeBackgroundServices();
          });
          runApp(const ProviderScope(child: SFCApp()));
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
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: 'SFC App - Storage Facility Creator',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      routerConfig: router,
      builder: (context, child) {
        // Scale text for readability on phone/tablet; prevent words running together
        final media = MediaQuery.of(context);
        final width = media.size.width;
        final systemScale = media.textScaleFactor;
        double scaleFactor;
        if (kIsWeb && width < 1024) {
          // Phone/tablet: keep at least 1.0 so text doesn't shrink and cramp
          scaleFactor = systemScale.clamp(1.0, 1.4);
        } else {
          scaleFactor = systemScale.clamp(0.9, 1.3);
        }
        return MediaQuery(
          data: media.copyWith(
            textScaleFactor: scaleFactor,
            boldText: media.boldText,
          ),
          child: ScrollConfiguration(
            behavior: const _AppScrollBehavior(),
            child: ErrorBanner(
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        );
      },
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

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const AlwaysScrollableScrollPhysics(
      parent: ClampingScrollPhysics(),
    );
  }
}

