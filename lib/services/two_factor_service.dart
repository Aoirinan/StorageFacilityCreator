import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'app_check_service.dart';

/// Service for handling two-factor authentication via email OTP
class TwoFactorService {
  static final FirebaseFunctions _functions = FirebaseFunctions.instance;
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Request an OTP code to be sent to the user's email
  /// 
  /// [purpose] - Optional purpose for the OTP (e.g., 'sensitive_action', 'login')
  /// Returns the expiration time in seconds
  static Future<TwoFactorResult> requestOTP({String? purpose}) async {
    try {
      if (kDebugMode) {
        print('🔐 [TwoFactorService] Requesting OTP code...');
      }

      final callable = _functions.httpsCallable('generateOTP');
      final result = await callable.call({
        if (purpose != null) 'purpose': purpose,
      });

      final data = result.data as Map<String, dynamic>;

      if (kDebugMode) {
        print('✅ [TwoFactorService] OTP code sent successfully');
        print('🔐 [TwoFactorService] Expires in: ${data['expiresIn']} seconds');
      }

      return TwoFactorResult(
        success: true,
        message: data['message'] as String? ?? 'OTP code sent to your email',
        expiresIn: data['expiresIn'] as int? ?? 600,
      );
    } on FirebaseFunctionsException catch (e) {
      if (kDebugMode) {
        print('❌ [TwoFactorService] Firebase Functions error: ${e.code} - ${e.message}');
      }

      // Check for rate limiting (429 errors) FIRST
      if (e.code == 'resource-exhausted' || 
          e.code == '429' ||
          e.message?.contains('429') == true ||
          e.message?.contains('Too Many Requests') == true ||
          e.message?.contains('wait') == true) {
        return TwoFactorResult(
          success: false,
          error: e.message ?? 'Please wait before requesting another OTP code.',
          errorCode: 'resource-exhausted',
        );
      }

      // Check if this is an App Check error
      if (e.code == 'failed-precondition' && 
          (e.message?.contains('App Check') == true || 
           e.message?.contains('app check') == true ||
           e.message?.contains('appCheck') == true)) {
        if (!AppCheckService.isActivated) {
          return TwoFactorResult(
            success: false,
            error: 'App Check is not enabled. The app needs to be rebuilt with App Check enabled.',
            errorCode: e.code,
          );
        } else {
          return TwoFactorResult(
            success: false,
            error: 'App Check verification failed. Please ensure App Check is properly configured.',
            errorCode: e.code,
          );
        }
      }

      return TwoFactorResult(
        success: false,
        error: _getErrorMessage(e),
        errorCode: e.code,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [TwoFactorService] Unexpected error: $e');
      }

      return TwoFactorResult(
        success: false,
        error: 'Failed to request OTP: $e',
      );
    }
  }

  /// Verify an OTP code
  /// 
  /// [code] - The 6-digit OTP code to verify
  /// [purpose] - Optional purpose for the OTP (must match the purpose used when requesting)
  static Future<TwoFactorResult> verifyOTP({
    required String code,
    String? purpose,
  }) async {
    try {
      if (kDebugMode) {
        print('🔐 [TwoFactorService] Verifying OTP code...');
      }

      // Validate code format
      if (code.length != 6 || !RegExp(r'^\d+$').hasMatch(code)) {
        return TwoFactorResult(
          success: false,
          error: 'OTP code must be a 6-digit number',
        );
      }

      final callable = _functions.httpsCallable('verifyOTP');
      final result = await callable.call({
        'code': code,
        if (purpose != null) 'purpose': purpose,
      });

      final data = result.data as Map<String, dynamic>;

      if (kDebugMode) {
        print('✅ [TwoFactorService] OTP code verified successfully');
      }

      return TwoFactorResult(
        success: true,
        message: data['message'] as String? ?? 'OTP code verified successfully',
      );
    } on FirebaseFunctionsException catch (e) {
      if (kDebugMode) {
        print('❌ [TwoFactorService] Firebase Functions error: ${e.code} - ${e.message}');
      }

      // Check if this is an App Check error
      if (e.code == 'failed-precondition' && 
          (e.message?.contains('App Check') == true || 
           e.message?.contains('app check') == true ||
           e.message?.contains('appCheck') == true)) {
        if (!AppCheckService.isActivated) {
          return TwoFactorResult(
            success: false,
            error: 'App Check is not enabled. The app needs to be rebuilt with App Check enabled.',
            errorCode: e.code,
          );
        } else {
          return TwoFactorResult(
            success: false,
            error: 'App Check verification failed. Please ensure App Check is properly configured.',
            errorCode: e.code,
          );
        }
      }

      return TwoFactorResult(
        success: false,
        error: _getErrorMessage(e),
        errorCode: e.code,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [TwoFactorService] Unexpected error: $e');
      }

      return TwoFactorResult(
        success: false,
        error: 'Failed to verify OTP: $e',
      );
    }
  }

  /// Check if 2FA is enabled for the current user
  static Future<bool> is2FAEnabled() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return false;

      final userDoc = await _firestore.collection('users').doc(user.uid).get();
      if (!userDoc.exists) return false;

      final data = userDoc.data();
      return data?['twoFactorEnabled'] == true;
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ [TwoFactorService] Error checking 2FA status: $e');
      }
      return false;
    }
  }

  /// Enable 2FA for the current user
  static Future<bool> enable2FA() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return false;

      await _firestore.collection('users').doc(user.uid).update({
        'twoFactorEnabled': true,
      });

      if (kDebugMode) {
        print('✅ [TwoFactorService] 2FA enabled for user ${user.uid}');
      }

      return true;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [TwoFactorService] Error enabling 2FA: $e');
      }
      return false;
    }
  }

  /// Disable 2FA for the current user
  static Future<bool> disable2FA() async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        if (kDebugMode) {
          print('❌ [TwoFactorService] Cannot disable 2FA: User not authenticated');
        }
        return false;
      }

      if (kDebugMode) {
        print('🔄 [TwoFactorService] Disabling 2FA for user ${user.uid}');
      }

      // Update the twoFactorEnabled field
      await _firestore.collection('users').doc(user.uid).update({
        'twoFactorEnabled': false,
        'lastOTPSentAt': FieldValue.delete(), // Clear rate limit timestamp
      });

      if (kDebugMode) {
        print('✅ [TwoFactorService] Updated twoFactorEnabled to false and cleared rate limit');
      }

      // Clean up all OTP codes for this user (optional - don't fail if this fails)
      try {
        final otpCodesSnapshot = await _firestore
            .collection('users')
            .doc(user.uid)
            .collection('otpCodes')
            .get();

        if (otpCodesSnapshot.docs.isNotEmpty) {
          final batch = _firestore.batch();
          for (final doc in otpCodesSnapshot.docs) {
            batch.delete(doc.reference);
          }
          await batch.commit();
          if (kDebugMode) {
            print('✅ [TwoFactorService] Cleaned up ${otpCodesSnapshot.docs.length} OTP codes');
          }
        }
      } catch (cleanupError) {
        // Don't fail the entire operation if cleanup fails
        if (kDebugMode) {
          print('⚠️ [TwoFactorService] Error cleaning up OTP codes (non-fatal): $cleanupError');
        }
      }

      if (kDebugMode) {
        print('✅ [TwoFactorService] 2FA disabled successfully for user ${user.uid}');
      }

      return true;
    } catch (e, stackTrace) {
      if (kDebugMode) {
        print('❌ [TwoFactorService] Error disabling 2FA: $e');
        print('Stack trace: $stackTrace');
        if (e.toString().contains('permission-denied')) {
          print('🚨 PERMISSION DENIED: Check Firestore security rules for users/{uid}');
        }
      }
      return false;
    }
  }

  /// Get user-friendly error message from Firebase Functions exception
  static String _getErrorMessage(FirebaseFunctionsException e) {
    switch (e.code) {
      case 'unauthenticated':
        return 'You must be logged in to use 2FA';
      case 'permission-denied':
        return 'Invalid OTP code. Please try again.';
      case 'invalid-argument':
        return 'Invalid OTP code format. Please enter a 6-digit number.';
      case 'not-found':
        return 'No valid OTP code found. Please request a new code.';
      case 'deadline-exceeded':
        return 'OTP code has expired. Please request a new code.';
      case 'resource-exhausted':
        return e.message ?? 'Too many requests. Please wait before requesting another code.';
      case 'failed-precondition':
        return e.message ?? 'A precondition failed. Please try again.';
      case 'internal':
        return '2FA service temporarily unavailable. Please try again later.';
      default:
        return e.message ?? 'An unknown error occurred';
    }
  }
}

/// Result of a 2FA operation
class TwoFactorResult {
  final bool success;
  final String? message;
  final String? error;
  final String? errorCode;
  final int? expiresIn; // For OTP requests, time until expiration in seconds

  const TwoFactorResult({
    required this.success,
    this.message,
    this.error,
    this.errorCode,
    this.expiresIn,
  });

  @override
  String toString() {
    if (success) {
      return 'TwoFactorResult(success: true, message: $message, expiresIn: $expiresIn)';
    } else {
      return 'TwoFactorResult(success: false, error: $error, errorCode: $errorCode)';
    }
  }
}
