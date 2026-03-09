import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:state_notifier/state_notifier.dart';
import '../services/auth_service.dart';
import '../services/ownership_repair_service.dart';

// Auth service provider
final authServiceProvider = Provider<AuthService>((ref) => AuthService());

// Current user provider
final authStateProvider = StreamProvider<User?>((ref) {
  final authService = ref.watch(authServiceProvider);
  return authService.authStateChanges;
});

// Login state provider
final loginStateProvider = StateNotifierProvider<LoginStateNotifier, AsyncValue<void>>((ref) {
  return LoginStateNotifier(ref.watch(authServiceProvider));
});

class LoginStateNotifier extends StateNotifier<AsyncValue<void>> {
  final AuthService _authService;

  LoginStateNotifier(this._authService) : super(const AsyncValue.data(null));

  Future<bool> signIn({required String email, required String password}) async {
    state = const AsyncValue.loading();
    try {
      await _authService.signInWithEmailAndPassword(email: email, password: password);
      await _authService.updateLastLogin();
      
      // Automatically check and repair ownership issues after login
      // This fixes cases where facility/account ownership gets out of sync after subscription
      OwnershipRepairService.checkAndRepairOwnership();
      
      state = const AsyncValue.data(null);
      return true; // Return true on success
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
      return false; // Return false on error
    }
  }

  Future<void> signUp({
    required String name,
    required String email,
    required String password,
  }) async {
    state = const AsyncValue.loading();
    try {
      // This will send verification email but not create user document yet
      await _authService.createUserWithEmailAndPassword(
        email: email,
        password: password,
        tosAccepted: true,
      );
      // Don't complete signup here - wait for email verification
      // The user document will be created after email is verified
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> resetPassword({required String email}) async {
    state = const AsyncValue.loading();
    try {
      await _authService.sendPasswordResetEmail(email: email);
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> sendPasswordReset({required String email}) async {
    state = const AsyncValue.loading();
    try {
      await _authService.sendPasswordResetEmail(email: email);
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }

  Future<void> signOut() async {
    state = const AsyncValue.loading();
    try {
      await _authService.signOut();
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }
}

// Form validation helpers
class AuthValidators {
  static String? validateEmail(String? value) {
    if (value == null || value.isEmpty) {
      return 'Email is required';
    }
    final emailRegex = RegExp(r'^[^@]+@[^@]+\.[^@]+');
    if (!emailRegex.hasMatch(value)) {
      return 'Please enter a valid email';
    }
    return null;
  }

  static String? validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Password is required';
    }
    if (value.length < 6) {
      return 'Password must be at least 6 characters';
    }
    return null;
  }

  static String? validateConfirmPassword(String? value, String password) {
    if (value == null || value.isEmpty) {
      return 'Confirm password is required';
    }
    if (value != password) {
      return 'Passwords do not match';
    }
    return null;
  }

  static String? validateName(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Please enter your full name';
    }
    if (value.trim().length < 2) {
      return 'Name must be at least 2 characters';
    }
    return null;
  }
}

// Signup state provider
final signupStateProvider = StateNotifierProvider<LoginStateNotifier, AsyncValue<void>>((ref) {
  return LoginStateNotifier(ref.watch(authServiceProvider));
});

// Forgot password state provider
final forgotPasswordStateProvider = StateNotifierProvider<LoginStateNotifier, AsyncValue<void>>((ref) {
  return LoginStateNotifier(ref.watch(authServiceProvider));
});
