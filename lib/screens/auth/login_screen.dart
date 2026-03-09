import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../../providers/auth_provider.dart';
import '../../providers/two_factor_provider.dart';
import 'signup_screen.dart';
import 'forgot_password_screen.dart';
import '../home_screen_modern.dart';
import '../tenant_portal_access_screen.dart';
import '../../router/app_router.dart';
import '../../router/app_route.dart';
import '../../services/home_button_service.dart';
import '../../services/superadmin_service.dart';
import '../../services/two_factor_service.dart';
import '../../widgets/otp_input_dialog.dart';
import '../../theme/app_theme.dart';
import '../../widgets/language_selector.dart';
import '../../services/debug_session_logger.dart';

class LoginScreen extends ConsumerStatefulWidget {
  final String? initialEmail;
  final String? redirectAfterLogin;

  const LoginScreen({super.key, this.initialEmail, this.redirectAfterLogin});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _hasChecked2FA = false; // Flag to prevent multiple 2FA checks

  @override
  void initState() {
    super.initState();
    if (widget.initialEmail != null && widget.initialEmail!.isNotEmpty) {
      _emailController.text = widget.initialEmail!;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      HomeButtonService.instance.hide();
      // Reset the flag when screen is first shown (user might be coming back to login)
      _hasChecked2FA = false;
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    // Don't reset _hasChecked2FA on dispose - it should persist during the login flow
    HomeButtonService.instance.show();
    super.dispose();
  }

  Future<void> _handle2FAVerification() async {
    if (!mounted) return;
    
    // Check if OTP request is already in progress
    if (ref.read(otpRequestInProgressProvider)) {
      return; // Already requesting, don't duplicate
    }
    
    // Mark that we're requesting OTP
    ref.read(otpRequestInProgressProvider.notifier).state = true;
    
    try {
      // Request OTP first
      final otpRequestResult = await TwoFactorService.requestOTP(purpose: 'login');
      
      if (!otpRequestResult.success) {
        // Check if it's a rate limit or service error (don't sign out)
        if (otpRequestResult.errorCode == 'resource-exhausted' || 
            otpRequestResult.error?.contains('wait') == true ||
            otpRequestResult.error?.contains('429') == true ||
            otpRequestResult.error?.contains('500') == true ||
            otpRequestResult.error?.contains('Internal Server Error') == true ||
            otpRequestResult.error?.contains('temporarily unavailable') == true) {
          // Rate limited or service error - show dialog with error so user can retry
          String errorMsg = otpRequestResult.error ?? 'The verification service is temporarily unavailable.';
          if (otpRequestResult.errorCode == 'resource-exhausted' || 
              otpRequestResult.error?.contains('429') == true) {
            errorMsg = 'Please wait before requesting another code. The code request limit has been reached.';
          } else if (otpRequestResult.error?.contains('500') == true ||
                     otpRequestResult.error?.contains('Internal Server Error') == true) {
            errorMsg = 'The verification service is temporarily unavailable. Please try again in a moment.';
          }
          
          // Show dialog with error message - user can retry from within the dialog
          final otpCode = await showOTPInputDialog(
            context,
            purpose: 'login',
            actionName: 'complete login',
            message: 'Please enter the 6-digit code sent to your email to complete login.',
            onRequestOTP: () => TwoFactorService.requestOTP(purpose: 'login'),
            initialErrorMessage: errorMsg,
          );
          
          // Handle the result from dialog
          if (otpCode == null || !mounted) {
            // User cancelled or verification failed - sign them out
            await ref.read(loginStateProvider.notifier).signOut();
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Login cancelled. Please sign in again.'),
                  backgroundColor: AppTheme.warning,
                ),
              );
            }
            return;
          }
          
          // Mark 2FA as verified for this session
          ref.read(twoFactorVerifiedProvider.notifier).state = true;
          // #region agent log
          debugSessionLog(hypothesisId: 'H4', location: 'login_screen.dart:_handle2FA:rateLimitSuccess', message: '2FA rate-limit path: about to go(destination)');
          // #endregion
          // Navigate via router ref so we don't depend on widget context (avoids no-nav when refresh disposes login)
          final _dest1 = widget.redirectAfterLogin ??
              (SuperAdminService.isSuperAdmin() ? AppRoute.superAdmin : AppRoute.dashboard);
          ref.read(goRouterProvider).go(_dest1);
          return;
        } else {
          // Other errors - sign out and show error
          await ref.read(loginStateProvider.notifier).signOut();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(otpRequestResult.error ?? 'Failed to send verification code. Please try again.'),
                backgroundColor: AppTheme.error,
              ),
            );
          }
          return;
        }
      }

      // OTP request succeeded - show dialog (code already sent, so show "Code sent" + Resend)
      final otpCode = await showOTPInputDialog(
        context,
        purpose: 'login',
        actionName: 'complete login',
        message: 'Please enter the 6-digit code sent to your email to complete login.',
        onRequestOTP: () => TwoFactorService.requestOTP(purpose: 'login'),
        initialOtpRequested: true,
        initialExpiresIn: otpRequestResult.expiresIn ?? 600,
      );

      if (otpCode == null || !mounted) {
        // User cancelled or verification failed - sign them out
        await ref.read(loginStateProvider.notifier).signOut();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Login cancelled. Please sign in again.'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
        return;
      }
      
      // Mark 2FA as verified for this session
      ref.read(twoFactorVerifiedProvider.notifier).state = true;
      // #region agent log
      debugSessionLog(hypothesisId: 'H4', location: 'login_screen.dart:_handle2FA:success', message: '2FA success path: about to go(destination)');
      // #endregion
      // Navigate via router ref so we don't depend on widget context (avoids no-nav when refresh disposes login)
      final _dest2 = widget.redirectAfterLogin ??
          (SuperAdminService.isSuperAdmin() ? AppRoute.superAdmin : AppRoute.dashboard);
      ref.read(goRouterProvider).go(_dest2);
    } finally {
      // Always reset the OTP request flag
      if (mounted) {
        ref.read(otpRequestInProgressProvider.notifier).state = false;
      }
    }
  }

  void _handleSignIn() async {
    if (_formKey.currentState!.validate()) {
      // #region agent log
      debugSessionLog(hypothesisId: 'H1', location: 'login_screen.dart:_handleSignIn:entry', message: 'Sign-in attempt', data: {'mounted': mounted});
      // #endregion
      final result = await ref.read(loginStateProvider.notifier).signIn(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );

      // #region agent log
      debugSessionLog(hypothesisId: 'H1', location: 'login_screen.dart:_handleSignIn:afterSignIn', message: 'Sign-in result', data: {'result': result, 'mounted': mounted});
      // #endregion

      // Check if login was successful (don't require mounted—we navigate via router ref)
      if (result == true) {
        // Wait for auth stream to emit user so route guard sees authenticated when we go(dashboard).
        var user = ref.read(authStateProvider).whenOrNull(data: (d) => d);
        for (var i = 0; i < 40 && user == null; i++) {
          await Future.delayed(const Duration(milliseconds: 50));
          user = ref.read(authStateProvider).whenOrNull(data: (d) => d);
        }
        // #region agent log
        debugSessionLog(hypothesisId: 'H2', location: 'login_screen.dart:_handleSignIn:afterAuthWait', message: 'Auth wait done', data: {'hasUser': user != null, 'mounted': mounted});
        // #endregion

        // Invalidate cache and get fresh 2FA status (important after enabling 2FA)
        ref.invalidate(twoFactorEnabledProvider);
        final is2FAEnabled = await TwoFactorService.is2FAEnabled();

        // #region agent log
        debugSessionLog(hypothesisId: 'H2', location: 'login_screen.dart:_handleSignIn:afterIs2FA', message: 'After is2FAEnabled', data: {'is2FAEnabled': is2FAEnabled, 'mounted': mounted});
        // #endregion

        if (is2FAEnabled) {
          if (!mounted) return; // need context for OTP dialog
          // #region agent log
          debugSessionLog(hypothesisId: 'H5', location: 'login_screen.dart:_handleSignIn:branch2FA', message: 'Taking 2FA branch, calling _handle2FAVerification');
          // #endregion
          _hasChecked2FA = true;
          await _handle2FAVerification();
          return;
        } else {
          // No 2FA: re-check immediately before navigating to avoid bypassing 2FA (e.g. stale/cache).
          ref.invalidate(twoFactorEnabledProvider);
          final is2FAEnabledAgain = await TwoFactorService.is2FAEnabled();
          if (is2FAEnabledAgain && mounted) {
            _hasChecked2FA = true;
            await _handle2FAVerification();
            return;
          }
          _hasChecked2FA = true;
          ref.read(twoFactorVerifiedProvider.notifier).state = true;
          final destination = widget.redirectAfterLogin ??
              (SuperAdminService.isSuperAdmin()
                  ? AppRoute.superAdmin
                  : AppRoute.dashboard);
          ref.read(goRouterProvider).go(destination);
          // #region agent log
          debugSessionLog(hypothesisId: 'H4', location: 'login_screen.dart:_handleSignIn:branchNo2FA', message: 'No-2FA branch, go(destination) called', data: {'mounted': mounted, 'destination': destination});
          // #endregion
        }
      } else {
        // #region agent log
        debugSessionLog(hypothesisId: 'H1', location: 'login_screen.dart:_handleSignIn:skipBlock', message: 'Skipped success block', data: {'result': result, 'mounted': mounted});
        // #endregion
      }
    }
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppTheme.error,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _getErrorMessage(dynamic error) {
    if (error is FirebaseAuthException) {
      switch (error.code) {
        case 'user-not-found':
          return 'No user found with this email address.';
        case 'wrong-password':
          return 'Incorrect password.';
        case 'invalid-email':
          return 'Please enter a valid email address.';
        case 'user-disabled':
          return 'This account has been disabled.';
        case 'too-many-requests':
          return 'Too many failed attempts. Please try again later.';
        default:
          return error.message ?? 'An error occurred during sign in.';
      }
    }
    return 'An unexpected error occurred.';
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final loginState = ref.watch(loginStateProvider);
    final isMobile = MediaQuery.of(context).size.width < 600;
    final is2FAVerified = ref.watch(twoFactorVerifiedProvider);
    final otpRequestInProgress = ref.watch(otpRequestInProgressProvider);

    // Check if user is authenticated but needs 2FA verification
    // Only check if we haven't already handled it in _handleSignIn
    // This handles the case where user is already logged in (e.g., page refresh)
    if (!_hasChecked2FA && !loginState.isLoading) {
      authState.whenData((user) async {
        if (user != null && !is2FAVerified && !otpRequestInProgress && mounted) {
          // Only trigger if this is NOT from a fresh login (avoid double-checking)
          // We check if loginState is not loading to avoid race condition with _handleSignIn
          final loginStateValue = ref.read(loginStateProvider);
          if (loginStateValue.isLoading) {
            // Login is in progress, let _handleSignIn handle 2FA
            return;
          }
          
          _hasChecked2FA = true; // Mark as checked to prevent duplicates
          
          // Invalidate cache and get fresh 2FA status
          ref.invalidate(twoFactorEnabledProvider);
          final is2FAEnabled = await TwoFactorService.is2FAEnabled();
          
          if (is2FAEnabled && mounted && !otpRequestInProgress) {
            // Do NOT set otpRequestInProgress here - _handle2FAVerification sets it and would return early if already true
            // Show 2FA dialog immediately (only once)
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _handle2FAVerification().then((_) {
                  // Flag is reset in _handle2FAVerification finally block
                  if (mounted) {
                    ref.read(otpRequestInProgressProvider.notifier).state = false;
                  }
                });
              }
            });
          } else if (!is2FAEnabled && mounted) {
            // Re-check before navigating; if 2FA enabled now, show OTP instead.
            ref.invalidate(twoFactorEnabledProvider);
            final is2FAEnabledAgain = await TwoFactorService.is2FAEnabled();
            if (is2FAEnabledAgain && mounted && !ref.read(otpRequestInProgressProvider)) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _handle2FAVerification();
              });
              return;
            }
            if (!mounted) return;
            // #region agent log
            debugSessionLog(hypothesisId: 'H5', location: 'login_screen.dart:build:alreadyLoggedInNo2FA', message: 'Build path: already logged in, no 2FA, go(destination)');
            // #endregion
            ref.read(twoFactorVerifiedProvider.notifier).state = true;
            final _dest3 = widget.redirectAfterLogin ??
                (SuperAdminService.isSuperAdmin() ? AppRoute.superAdmin : AppRoute.dashboard);
            ref.read(goRouterProvider).go(_dest3);
          }
        }
      });
    }

    // Show error message if login fails
    loginState.whenOrNull(
      error: (error, stackTrace) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showErrorSnackBar(_getErrorMessage(error));
        });
      },
    );

    return Scaffold(
      backgroundColor: AppTheme.primaryBlueDark,
      body: SafeArea(
        child: Stack(
          children: [
            SingleChildScrollView(
              padding: EdgeInsets.all(isMobile ? 16.0 : 24.0),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: isMobile ? 40 : 80),
                
                // Logo and title - responsive sizing
                Container(
                  padding: EdgeInsets.all(isMobile ? 16 : 20),
                  decoration: BoxDecoration(
                    color: AppTheme.textOnDark.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(
                    Icons.storage,
                    size: isMobile ? 64 : 100,
                    color: AppTheme.textOnDark,
                  ),
                ),
                SizedBox(height: isMobile ? 24 : 40),
                
                Text(
                  'Storage Facility Creator',
                  style: TextStyle(
                    fontSize: isMobile ? 24 : 28,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textOnDark,
                    letterSpacing: 1.2,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                
                Text(
                  'Professional Storage Management',
                  style: TextStyle(
                    fontSize: isMobile ? 14 : 16,
                    color: AppTheme.textOnDark.withOpacity(0.7),
                    letterSpacing: 0.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                
                Text(
                  'Sign in to your account',
                  style: TextStyle(
                    fontSize: isMobile ? 12 : 14,
                    color: AppTheme.textOnDark.withOpacity(0.6),
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: isMobile ? 32 : 48),

                // Email field
                TextFormField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  validator: AuthValidators.validateEmail,
                  style: TextStyle(color: AppTheme.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Email',
                    labelStyle: TextStyle(color: AppTheme.textSecondary),
                    floatingLabelBehavior: FloatingLabelBehavior.never,
                    prefixIcon: Icon(Icons.email_outlined, color: AppTheme.primaryBlue),
                    filled: true,
                    fillColor: AppTheme.surface,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 16, 
                      vertical: isMobile ? 12 : 16
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: AppTheme.borderLight),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: AppTheme.borderLight),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: AppTheme.primaryBlue, width: 2),
                    ),
                    errorBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: AppTheme.error),
                    ),
                    focusedErrorBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: AppTheme.error, width: 2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Password field
                TextFormField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  textInputAction: TextInputAction.done,
                  validator: AuthValidators.validatePassword,
                  onFieldSubmitted: (_) => _handleSignIn(),
                  style: TextStyle(color: AppTheme.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    labelStyle: TextStyle(color: AppTheme.textSecondary),
                    floatingLabelBehavior: FloatingLabelBehavior.never,
                    prefixIcon: Icon(Icons.lock_outlined, color: AppTheme.primaryBlue),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword ? Icons.visibility : Icons.visibility_off,
                        color: AppTheme.primaryBlue,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscurePassword = !_obscurePassword;
                        });
                      },
                    ),
                    filled: true,
                    fillColor: AppTheme.surface,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 16, 
                      vertical: isMobile ? 12 : 16
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: AppTheme.borderLight),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: AppTheme.borderLight),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: AppTheme.primaryBlue, width: 2),
                    ),
                    errorBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: AppTheme.error),
                    ),
                    focusedErrorBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: AppTheme.error, width: 2),
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                // Forgot password
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => context.go(AppRoute.forgotPassword),
                    child: Text(
                      'Forgot Password?',
                      style: TextStyle(
                        color: AppTheme.textOnDark.withOpacity(0.7),
                        fontSize: isMobile ? 12 : 14,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // Sign in button
                ElevatedButton(
                  onPressed: loginState.isLoading ? null : _handleSignIn,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.surface,
                    foregroundColor: AppTheme.primaryBlueDark,
                    padding: EdgeInsets.symmetric(
                      vertical: isMobile ? 12 : 16
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 2,
                  ),
                  child: loginState.isLoading
                      ? SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primaryBlueDark),
                          ),
                        )
                      : Text(
                          'Sign In',
                          style: TextStyle(
                            fontSize: isMobile ? 14 : 16, 
                            fontWeight: FontWeight.w600
                          ),
                        ),
                ),
                const SizedBox(height: 24),

                // Sign up link
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Don\'t have an account? ',
                      style: TextStyle(
                        color: AppTheme.textOnDark.withOpacity(0.7),
                        fontSize: isMobile ? 12 : 14,
                      ),
                    ),
                    TextButton(
                      onPressed: () => context.go(AppRoute.signup),
                      child: Text(
                        'Sign Up',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textOnDark,
                          fontSize: isMobile ? 12 : 14,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: () => context.go('/tenant-portal'),
                  icon: Icon(Icons.vpn_key_outlined, color: AppTheme.textOnDark.withOpacity(0.7)),
                  label: Text(
                    'Tenant Portal',
                    style: TextStyle(color: AppTheme.textOnDark.withOpacity(0.7)),
                  ),
                ),
                if (isDebugSessionEnabled()) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () {
                      final lines = debugSessionLogLines();
                      if (lines.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('No debug log yet. Sign in first, then copy.')),
                        );
                        return;
                      }
                      Clipboard.setData(ClipboardData(text: lines.join('\n')));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Copied ${lines.length} debug log line(s) to clipboard.')),
                      );
                    },
                    icon: Icon(Icons.copy, size: 14, color: AppTheme.textOnDark.withOpacity(0.5)),
                    label: Text(
                      'Copy debug log',
                      style: TextStyle(fontSize: 11, color: AppTheme.textOnDark.withOpacity(0.5)),
                    ),
                  ),
                ],
                SizedBox(height: isMobile ? 20 : 40),
                  ],
                ),
              ),
            ),
            // Language selector in top-right corner
            Positioned(
              top: 16,
              right: 16,
              child: Container(
                decoration: BoxDecoration(
                  color: AppTheme.surface.withOpacity(0.95),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.textPrimary.withOpacity(0.1),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: const LanguageSelector(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}