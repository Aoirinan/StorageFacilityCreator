import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb, debugPrint;
import 'package:sfcapp/services/permission_service.dart';
import 'package:sfcapp/services/app_check_service.dart';
import 'package:sfcapp/services/ai_debug_logger.dart';
import 'package:sfcapp/services/debug_logger.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Get current user
  User? get currentUser => _auth.currentUser;

  // Auth state stream
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // Sign in with email and password
  Future<UserCredential?> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    // #region agent log
    DebugLogger.log(
      hypothesisId: 'H2',
      location: 'auth_service.dart:signInWithEmailAndPassword.entry',
      message: 'Sign-in attempt started',
      data: {'emailProvided': email.isNotEmpty, 'passwordProvided': password.isNotEmpty},
    );
    // #endregion
    try {
      // Check App Check token availability before auth request (H1, H2, H4)
      // Force refresh token if it's old to prevent expiration issues
      // #region agent log
      final appCheckStats = AppCheckService.getMonitoringStats();
      final isLocalhost = kIsWeb &&
          (Uri.base.host == 'localhost' || Uri.base.host == '127.0.0.1');
      // Capture full URL for debugging referer issues
      final fullUrl = kIsWeb ? Uri.base.toString() : 'not-web';
      // #region agent log
      aiDebugLog(
        sessionId: 'debug-session',
        runId: 'pre-fix',
        hypothesisId: 'H10',
        location: 'auth_service.dart:signInWithEmailAndPassword.urlCapture',
        message: 'Captured full URL for referer debugging',
        data: {
          'fullUrl': fullUrl,
          'host': Uri.base.host,
          'port': Uri.base.port,
          'scheme': Uri.base.scheme,
          'isLocalhost': isLocalhost,
        },
      );
      // #endregion
      // H10: Try to get App Check token even on localhost (if App Check is activated)
      // Firebase Auth might require App Check tokens even on localhost
      String? appCheckToken;
      if (isLocalhost) {
        // Try to get token even on localhost (if App Check was activated in debug mode)
        appCheckToken = await AppCheckService.getToken(forceRefresh: true);
        if (kDebugMode) {
          debugPrint('App Check token on localhost: ${appCheckToken != null ? "obtained" : "not available"}');
        }
        // #region agent log
        aiDebugLog(
          sessionId: 'debug-session',
          runId: 'pre-fix',
          hypothesisId: 'H10',
          location: 'auth_service.dart:signInWithEmailAndPassword.localhostTokenAttempt',
          message: 'Attempted App Check token on localhost',
          data: {
            'host': Uri.base.host,
            'fullUrl': fullUrl,
            'tokenObtained': appCheckToken != null,
            'tokenLength': appCheckToken?.length ?? 0,
          },
        );
        // #endregion
      } else {
        // Don't block login if App Check token is slow/failing (e.g. custom domain not yet authorized)
        appCheckToken = await AppCheckService.getToken(forceRefresh: true)
            .timeout(const Duration(seconds: 4), onTimeout: () => null);
      }
      DebugLogger.log(
        hypothesisId: 'H2',
        location: 'auth_service.dart:signInWithEmailAndPassword.beforeAuth',
        message: 'App Check status before auth request',
        data: {
          'appCheckActivated': appCheckStats['isActivated'] ?? false,
          'tokenAvailable': appCheckToken != null,
          'tokenLength': appCheckToken?.length ?? 0,
          'tokenSuccessCount': appCheckStats['tokenSuccessCount'] ?? 0,
          'tokenFailureCount': appCheckStats['tokenFailureCount'] ?? 0,
        },
      );
      // #endregion
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H5',
        location: 'auth_service.dart:signInWithEmailAndPassword.requestParams',
        message: 'Auth request parameters',
        data: {'emailLength': email.length, 'passwordLength': password.length},
      );
      // #endregion
      // #region agent log
      aiDebugLog(
        sessionId: 'debug-session',
        runId: 'pre-fix',
        hypothesisId: 'H7',
        location: 'auth_service.dart:signInWithEmailAndPassword.beforeAuthCall',
        message: 'About to call signInWithEmailAndPassword',
        data: {
          'appCheckToken': appCheckToken != null,
          'appCheckTokenLength': appCheckToken?.length ?? 0,
          'isLocalhost': isLocalhost,
          'email': email,
        },
      );
      // #endregion
      final credential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      if (kDebugMode) {
        print('✅ User signed in: ${credential.user?.email}');
      }
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H2',
        location: 'auth_service.dart:signInWithEmailAndPassword.success',
        message: 'Sign-in succeeded',
        data: {'userEmail': credential.user?.email},
      );
      // #endregion
      
      // Update last login timestamp
      await updateLastLogin();
      
      return credential;
    } on FirebaseAuthException catch (e) {
      if (kDebugMode) {
        print('❌ Sign in error: ${e.message}');
        // Check for localhost blocking error
        if (e.code.contains('requests-from-referer') && e.code.contains('localhost')) {
          print('');
          print('🚨 LOCALHOST BLOCKED BY FIREBASE AUTH');
          print('═══════════════════════════════════════════════════════');
          print('Firebase Auth is blocking requests from localhost.');
          print('Error code: ${e.code}');
          print('Current URL: ${kIsWeb ? Uri.base.toString() : "N/A"}');
          print('');
          print('NOTE: Even if localhost is in authorized domains, Firebase');
          print('may block based on HTTP Referer header (which includes port).');
          print('');
          print('SOLUTION 1: Try adding the specific port to authorized domains');
          print('1. Go to Firebase Console: https://console.firebase.google.com');
          print('2. Select your project');
          print('3. Go to Authentication > Settings > Authorized domains');
          print('4. Click "Add domain" and try adding: localhost:${Uri.base.port}');
          print('   (Note: This may not work - Firebase may not accept ports)');
          print('');
          print('SOLUTION 2: Use Firebase Emulators (RECOMMENDED)');
          print('Run: flutter run -d chrome --dart-define=USE_EMULATORS=true');
          print('(Make sure Firebase Emulators are running: firebase emulators:start)');
          print('');
          print('SOLUTION 3: Check Firebase App Check settings');
          print('App Check might be enforced at project level. Check:');
          print('Firebase Console > App Check > Apps > Your web app');
          print('═══════════════════════════════════════════════════════');
          print('');
        }
      }
      // #region agent log
      DebugLogger.log(
        hypothesisId: 'H2',
        location: 'auth_service.dart:signInWithEmailAndPassword.error',
        message: 'Sign-in failed with FirebaseAuthException',
        data: {
          'errorCode': e.code,
          'errorMessage': e.message,
          'errorType': 'FirebaseAuthException',
        },
      );
      // #endregion
      // #region agent log
      aiDebugLog(
        sessionId: 'debug-session',
        runId: 'pre-fix',
        hypothesisId: 'H7',
        location: 'auth_service.dart:signInWithEmailAndPassword.firebaseAuthException',
        message: 'FirebaseAuthException caught',
        data: {
          'code': e.code,
          'message': e.message ?? 'null',
          'credential': e.credential?.toString() ?? 'null',
          'email': e.email ?? 'null',
          'phoneNumber': e.phoneNumber ?? 'null',
        },
      );
      // #endregion
      rethrow;
    } catch (e, stackTrace) {
      // #region agent log
      aiDebugLog(
        sessionId: 'debug-session',
        runId: 'pre-fix',
        hypothesisId: 'H8',
        location: 'auth_service.dart:signInWithEmailAndPassword.unexpectedError',
        message: 'Unexpected error during sign-in',
        data: {
          'errorType': e.runtimeType.toString(),
          'errorMessage': e.toString(),
          'stackTrace': stackTrace.toString().substring(0, 500), // First 500 chars
        },
      );
      // #endregion
      if (kDebugMode) {
        print('❌ Unexpected sign in error: $e');
        print('Stack trace: $stackTrace');
      }
      rethrow;
    }
  }

  // Create user with email and password (requires email verification)
  Future<UserCredential?> createUserWithEmailAndPassword({
    required String email,
    required String password,
    required bool tosAccepted,
  }) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      if (credential.user != null) {
        // Send email verification before completing signup
        await credential.user!.sendEmailVerification();
        
        if (kDebugMode) {
          print('✅ Verification email sent to: ${credential.user?.email}');
        }
        
        // Don't create user document until email is verified
        // This prevents fake accounts from being created
        // The user document will be created when they verify their email
        
        if (kDebugMode) {
          print('⏳ Waiting for email verification before completing signup');
        }
      }
      
      return credential;
    } on FirebaseAuthException catch (e) {
      if (kDebugMode) {
        print('❌ Sign up error: ${e.message}');
      }
      rethrow;
    }
  }

  // Complete signup after email verification
  Future<void> completeSignupAfterVerification({
    required String email,
    required bool tosAccepted,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('User not authenticated');
      }

      if (!user.emailVerified) {
        throw Exception('Email not verified');
      }

      // Now create the user document since email is verified
      await _createUserDocument(
        uid: user.uid,
        email: email,
        tosAccepted: tosAccepted,
      );
      
      if (kDebugMode) {
        print('✅ User signup completed after email verification: ${user.email}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error completing signup: $e');
      }
      rethrow;
    }
  }

  // Check if user's email is verified
  Future<bool> isEmailVerified() async {
    final user = _auth.currentUser;
    if (user == null) return false;
    
    // Reload user to get latest verification status
    await user.reload();
    return _auth.currentUser?.emailVerified ?? false;
  }

  // Resend verification email
  Future<void> resendVerificationEmail() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User not authenticated');
    }
    
    if (user.emailVerified) {
      throw Exception('Email already verified');
    }
    
    await user.sendEmailVerification();
    
    if (kDebugMode) {
      print('✅ Verification email resent to: ${user.email}');
    }
  }

  // Create user document in Firestore
  Future<void> _createUserDocument({
    required String uid,
    required String email,
    required bool tosAccepted,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Attempting to create user document for $email (UID: $uid)');
      }
      
      // Use merge: true to avoid overwriting existing data
      final normalizedEmail = email.toLowerCase();

      await _firestore.collection('users').doc(uid).set({
        'email': email,
        'emailLower': normalizedEmail,
        'tosAccepted': tosAccepted,
        'tosAcceptedAt': tosAccepted ? FieldValue.serverTimestamp() : null,
        'createdAt': FieldValue.serverTimestamp(),
        'lastLoginAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await PermissionService.fulfillPendingInvitesForUser(
        userId: uid,
        emailLower: normalizedEmail,
        email: email,
        displayName: _auth.currentUser?.displayName,
      );
      
      if (kDebugMode) {
        print('✅ User document created successfully for $email');
        print('📄 Document path: users/$uid');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating user document: $e');
        print('🔍 Error type: ${e.runtimeType}');
        if (e.toString().contains('permission-denied')) {
          print('🚨 PERMISSION DENIED: Check Firestore security rules');
        }
      }
      rethrow;
    }
  }

  // Send password reset email
  Future<void> sendPasswordResetEmail({required String email}) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
      if (kDebugMode) {
        print('✅ Password reset email sent to $email');
      }
    } on FirebaseAuthException catch (e) {
      if (kDebugMode) {
        print('❌ Password reset error: ${e.message}');
      }
      rethrow;
    }
  }

  // Sign out
  Future<void> signOut() async {
    try {
      await _auth.signOut();
      if (kDebugMode) {
        print('✅ User signed out');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Sign out error: $e');
      }
      rethrow;
    }
  }

  // Update last login timestamp
  Future<void> updateLastLogin() async {
    if (currentUser != null) {
      try {
        await _firestore.collection('users').doc(currentUser!.uid).update({
          'lastLoginAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        if (kDebugMode) {
          print('❌ Error updating last login: $e');
        }
      }
    }
  }

  // Get user document from Firestore
  Future<DocumentSnapshot?> getUserDocument(String uid) async {
    try {
      return await _firestore.collection('users').doc(uid).get();
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting user document: $e');
      }
      return null;
    }
  }
}
