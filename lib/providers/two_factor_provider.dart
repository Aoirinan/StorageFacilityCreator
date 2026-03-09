import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import '../services/two_factor_service.dart';

/// Provider to track if 2FA has been verified for the current session
/// This is reset when the user logs out
final twoFactorVerifiedProvider = StateProvider<bool>((ref) => false);

/// Provider to track if 2FA verification is in progress
final twoFactorVerifyingProvider = StateProvider<bool>((ref) => false);

/// Provider to cache 2FA enabled status to avoid repeated Firestore calls
/// This is reset when the user logs out
final twoFactorEnabledProvider = FutureProvider<bool>((ref) async {
  return await TwoFactorService.is2FAEnabled();
});

/// Provider to track if we're currently requesting an OTP (to prevent duplicate requests)
final otpRequestInProgressProvider = StateProvider<bool>((ref) => false);
