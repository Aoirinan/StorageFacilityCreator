import 'package:flutter/material.dart';
import '../services/two_factor_service.dart';
import '../widgets/otp_input_dialog.dart';

/// Helper class for requiring 2FA before sensitive actions
class TwoFactorHelper {
  /// Require 2FA verification before proceeding with a sensitive action
  /// 
  /// Returns true if 2FA is not enabled OR if 2FA verification succeeded
  /// Returns false if 2FA is enabled but verification failed or was cancelled
  /// 
  /// Usage:
  /// ```dart
  /// final canProceed = await TwoFactorHelper.require2FA(
  ///   context: context,
  ///   purpose: 'delete_facility',
  ///   actionName: 'delete this facility',
  /// );
  /// 
  /// if (!canProceed) return; // User cancelled or verification failed
  /// 
  /// // Proceed with sensitive action
  /// await deleteFacility();
  /// ```
  static Future<bool> require2FA({
    required BuildContext context,
    required String purpose,
    String? actionName,
    String? customMessage,
  }) async {
    // Check if 2FA is enabled for the user
    final is2FAEnabled = await TwoFactorService.is2FAEnabled();
    
    if (!is2FAEnabled) {
      // 2FA is not enabled, allow action to proceed
      return true;
    }

    // 2FA is enabled, require verification
    final code = await showOTPInputDialog(
      context,
      purpose: purpose,
      actionName: actionName,
      message: customMessage ?? 'Please enter the 6-digit code sent to your email to proceed.',
    );

    // If code is null, user cancelled
    // If code is not null, verification succeeded (dialog only returns on success)
    return code != null;
  }

  /// Require 2FA with custom OTP request handler
  /// 
  /// Useful when you need to show custom UI or handle errors differently
  static Future<bool> require2FACustom({
    required BuildContext context,
    required String purpose,
    required Future<TwoFactorResult> Function() onRequestOTP,
    String? actionName,
    String? customMessage,
  }) async {
    final is2FAEnabled = await TwoFactorService.is2FAEnabled();
    
    if (!is2FAEnabled) {
      return true;
    }

    final code = await showOTPInputDialog(
      context,
      purpose: purpose,
      onRequestOTP: onRequestOTP,
      actionName: actionName,
      message: customMessage ?? 'Please enter the 6-digit code sent to your email to proceed.',
    );

    return code != null;
  }
}
