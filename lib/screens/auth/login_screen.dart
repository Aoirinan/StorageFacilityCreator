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
import '../../config/web_host_config.dart';
import '../../utils/browser_location_stub.dart'
    if (dart.library.html) '../../utils/browser_location_web.dart' as browser_location;
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
        // Enforce email verification before app access.
        final signedInUser = FirebaseAuth.instance.currentUser;
        if (signedInUser != null) {
          try {
            await signedInUser.reload();
          } catch (_) {
            // Ignore refresh failures and use current snapshot.
          }
          final refreshedUser = FirebaseAuth.instance.currentUser;
          if (refreshedUser != null &&
              !refreshedUser.emailVerified &&
              !SuperAdminService.isSuperAdmin(refreshedUser)) {
            ref.read(goRouterProvider).go(
                  '${AppRoute.verifyEmail}?email=${Uri.encodeComponent(refreshedUser.email ?? _emailController.text.trim())}',
                );
            return;
          }
        }

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
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 600;
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
      body: Stack(
        children: [
          // Gradient background
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF312E81), // indigo-900
                  AppTheme.primaryBlue,
                  Color(0xFF2563EB), // blue-600
                ],
                stops: [0.0, 0.55, 1.0],
              ),
            ),
          ),

          // Decorative blurred orbs for depth
          Positioned(
            top: -100,
            left: -80,
            child: _Orb(size: 320, color: Colors.white.withOpacity(0.06)),
          ),
          Positioned(
            bottom: -120,
            right: -100,
            child: _Orb(size: 380, color: AppTheme.accentYellow.withOpacity(0.08)),
          ),
          Positioned(
            top: screenWidth * 0.3,
            right: -60,
            child: _Orb(size: 220, color: AppTheme.accentBlueLight.withOpacity(0.08)),
          ),

          // Main content
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: isMobile ? 20 : 24,
                  vertical: 32,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Card
                      Container(
                        padding: EdgeInsets.all(isMobile ? 24 : 36),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.18),
                              blurRadius: 48,
                              offset: const Offset(0, 24),
                            ),
                            BoxShadow(
                              color: Colors.black.withOpacity(0.06),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Form(
                          key: _formKey,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Logo
                              Center(
                                child: Image.asset(
                                  'assets/images/logo.png',
                                  height: 56,
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, __, ___) => Container(
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      gradient: const LinearGradient(
                                        colors: [AppTheme.primaryBlue, AppTheme.primaryBlueLight],
                                      ),
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: const Icon(
                                      Icons.storage,
                                      size: 32,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 24),

                              // H1
                              const Text(
                                'Welcome back',
                                style: TextStyle(
                                  fontSize: 26,
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.textPrimary,
                                  letterSpacing: -0.5,
                                  height: 1.15,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 6),

                              // Subtitle
                              const Text(
                                'Sign in to your Storage Facility Creator account.',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: AppTheme.textSecondary,
                                  height: 1.5,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 28),

                              // Email
                              _FieldLabel('Email'),
                              const SizedBox(height: 6),
                              TextFormField(
                                controller: _emailController,
                                keyboardType: TextInputType.emailAddress,
                                textInputAction: TextInputAction.next,
                                validator: AuthValidators.validateEmail,
                                autofillHints: const [AutofillHints.email, AutofillHints.username],
                                style: const TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontSize: 15,
                                ),
                                decoration: _fieldDecoration(
                                  hint: 'you@company.com',
                                  icon: Icons.email_outlined,
                                ),
                              ),
                              const SizedBox(height: 16),

                              // Password
                              _FieldLabel('Password'),
                              const SizedBox(height: 6),
                              TextFormField(
                                controller: _passwordController,
                                obscureText: _obscurePassword,
                                textInputAction: TextInputAction.done,
                                validator: AuthValidators.validatePassword,
                                onFieldSubmitted: (_) => _handleSignIn(),
                                autofillHints: const [AutofillHints.password],
                                style: const TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontSize: 15,
                                ),
                                decoration: _fieldDecoration(
                                  hint: '••••••••',
                                  icon: Icons.lock_outlined,
                                  suffix: IconButton(
                                    splashRadius: 20,
                                    icon: Icon(
                                      _obscurePassword
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                      color: AppTheme.textTertiary,
                                      size: 20,
                                    ),
                                    onPressed: () {
                                      setState(() {
                                        _obscurePassword = !_obscurePassword;
                                      });
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),

                              // Forgot password (compact, right-aligned)
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: () => context.go(AppRoute.forgotPassword),
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 4,
                                    ),
                                    minimumSize: Size.zero,
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  child: const Text(
                                    'Forgot password?',
                                    style: TextStyle(
                                      color: AppTheme.primaryBlue,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 18),

                              // Sign In button (gradient)
                              _GradientSignInButton(
                                isLoading: loginState.isLoading,
                                onPressed: _handleSignIn,
                              ),
                              const SizedBox(height: 20),

                              // Sign up row
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Text(
                                    "Don't have an account?",
                                    style: TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 14,
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () {
                                      final r = widget.redirectAfterLogin;
                                      final e = _emailController.text.trim();
                                      if (r != null && r.isNotEmpty && e.isNotEmpty) {
                                        context.go(
                                          '${AppRoute.signup}?email=${Uri.encodeComponent(e)}&redirect=${Uri.encodeComponent(r)}',
                                        );
                                      } else if (r != null && r.isNotEmpty) {
                                        context.go(
                                          '${AppRoute.signup}?redirect=${Uri.encodeComponent(r)}',
                                        );
                                      } else if (e.isNotEmpty) {
                                        context.go(
                                          '${AppRoute.signup}?email=${Uri.encodeComponent(e)}',
                                        );
                                      } else {
                                        context.go(AppRoute.signup);
                                      }
                                    },
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 4,
                                      ),
                                      minimumSize: Size.zero,
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    child: const Text(
                                      'Sign up',
                                      style: TextStyle(
                                        color: AppTheme.primaryBlue,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 20),

                      // Secondary actions (white text on gradient, outside card)
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          _SecondaryLink(
                            icon: Icons.vpn_key_outlined,
                            label: 'Tenant Portal',
                            onPressed: () => context.go('/tenant-portal'),
                          ),
                          _SecondaryLink(
                            icon: Icons.home_outlined,
                            label: 'Main Page',
                            onPressed: () {
                              if (isProductionAppWebHost()) {
                                browser_location.assignWindowLocation(
                                  kMarketingWebsiteOrigin,
                                );
                              } else {
                                context.go(AppRoute.landing);
                              }
                            },
                          ),
                        ],
                      ),

                      if (isDebugSessionEnabled()) ...[
                        const SizedBox(height: 8),
                        Center(
                          child: TextButton.icon(
                            onPressed: () {
                              final lines = debugSessionLogLines();
                              if (lines.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'No debug log yet. Sign in first, then copy.',
                                    ),
                                  ),
                                );
                                return;
                              }
                              Clipboard.setData(
                                ClipboardData(text: lines.join('\n')),
                              );
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Copied ${lines.length} debug log line(s) to clipboard.',
                                  ),
                                ),
                              );
                            },
                            icon: Icon(
                              Icons.copy,
                              size: 12,
                              color: Colors.white.withOpacity(0.55),
                            ),
                            label: Text(
                              'Copy debug log',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.white.withOpacity(0.55),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Language selector in top-right corner
          Positioned(
            top: 16,
            right: 16,
            child: SafeArea(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.95),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.12),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const LanguageSelector(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _fieldDecoration({
    required String hint,
    required IconData icon,
    Widget? suffix,
  }) {
    const radius = 12.0;
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(
        color: AppTheme.textTertiary,
        fontSize: 14,
        fontWeight: FontWeight.w400,
      ),
      prefixIcon: Icon(icon, color: AppTheme.textTertiary, size: 20),
      suffixIcon: suffix,
      filled: true,
      fillColor: const Color(0xFFF8FAFC), // slate-50
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: AppTheme.borderLight, width: 1),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: AppTheme.borderLight, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: AppTheme.primaryBlue, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: AppTheme.error, width: 1),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: AppTheme.error, width: 2),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: AppTheme.textSecondary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
      ),
    );
  }
}

class _Orb extends StatelessWidget {
  final double size;
  final Color color;
  const _Orb({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
        ),
      ),
    );
  }
}

class _SecondaryLink extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  const _SecondaryLink({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(
        icon,
        size: 14,
        color: Colors.white.withOpacity(0.85),
      ),
      label: Text(
        label,
        style: TextStyle(
          color: Colors.white.withOpacity(0.85),
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _GradientSignInButton extends StatelessWidget {
  final bool isLoading;
  final VoidCallback onPressed;

  const _GradientSignInButton({
    required this.isLoading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [AppTheme.primaryBlue, AppTheme.primaryBlueLight],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: AppTheme.primaryBlue.withOpacity(0.4),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: isLoading ? null : onPressed,
            child: Center(
              child: isLoading
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Text(
                      'Sign In',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}