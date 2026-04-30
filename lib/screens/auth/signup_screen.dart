import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../../providers/auth_provider.dart';
import '../../services/home_button_service.dart';
import 'terms_screen.dart';
import 'privacy_screen.dart';
import '../../theme/app_theme.dart';
import '../../router/app_route.dart';
import '../../services/referral_program_service.dart';
import 'widgets/auth_shell.dart';

class SignupScreen extends ConsumerStatefulWidget {
  final String? initialEmail;
  final String? initialReferralCode;

  const SignupScreen({
    super.key,
    this.initialEmail,
    this.initialReferralCode,
  });

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _referralCodeController = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _acceptTerms = false;

  @override
  void initState() {
    super.initState();
    final pre = widget.initialEmail;
    if (pre != null && pre.trim().isNotEmpty) {
      _emailController.text = pre.trim();
    }
    final ref = widget.initialReferralCode?.trim();
    if (ref != null && ref.isNotEmpty) {
      _referralCodeController.text = ref;
    }
    ReferralProgramService.cachePendingCodeFromQuery(widget.initialReferralCode);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      HomeButtonService.instance.hide();
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _referralCodeController.dispose();
    HomeButtonService.instance.show();
    super.dispose();
  }

  void _handleSignUp() async {
    if (_formKey.currentState!.validate() && _acceptTerms) {
      final email = _emailController.text.trim();
      final referral = _referralCodeController.text.trim();
      if (referral.isNotEmpty && referral.length < 4) {
        _showErrorSnackBar(
            'Referral codes must be at least 4 characters. Leave blank if you do not have one.');
        return;
      }
      if (referral.isNotEmpty) {
        await ReferralProgramService.cachePendingCodeFromQuery(referral);
      } else {
        await ReferralProgramService.clearPendingReferralCode();
      }

      try {
        await ref.read(signupStateProvider.notifier).signUp(
              name: _nameController.text.trim(),
              email: email,
              password: _passwordController.text,
            );

        if (mounted) {
          context.go(AppRoute.verifyEmail, extra: email);
        }
      } catch (e) {
        if (kDebugMode) {
          print('Signup error: $e');
        }
      }
    } else if (!_acceptTerms) {
      _showErrorSnackBar('Please accept the Terms of Service to continue.');
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
        case 'email-already-in-use':
          return 'An account already exists with this email address.';
        case 'invalid-email':
          return 'Please enter a valid email address.';
        case 'weak-password':
          return 'Password is too weak. Please choose a stronger password.';
        case 'operation-not-allowed':
          return 'Email/password accounts are not enabled.';
        default:
          return error.message ?? 'An error occurred during sign up.';
      }
    }
    return 'An unexpected error occurred.';
  }

  @override
  Widget build(BuildContext context) {
    final signupState = ref.watch(signupStateProvider);

    signupState.whenOrNull(
      error: (error, stackTrace) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showErrorSnackBar(_getErrorMessage(error));
        });
      },
    );

    return AuthShell(
      backButton: AuthShellBackButton(
        onPressed: () {
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          } else {
            context.go(AppRoute.login);
          }
        },
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AuthLogoHeader(
              title: 'Create your account',
              subtitle: 'Start managing your storage facilities in minutes.',
            ),
            const AuthFieldLabel('Full name'),
            const SizedBox(height: 6),
            TextFormField(
              controller: _nameController,
              textInputAction: TextInputAction.next,
              validator: AuthValidators.validateName,
              autofillHints: const [AutofillHints.name],
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 15,
              ),
              decoration: authFieldDecoration(
                hint: 'Jane Doe',
                icon: Icons.person_outlined,
              ),
            ),
            const SizedBox(height: 16),
            const AuthFieldLabel('Email'),
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
              decoration: authFieldDecoration(
                hint: 'you@company.com',
                icon: Icons.email_outlined,
              ),
            ),
            const SizedBox(height: 16),
            const AuthFieldLabel('Password'),
            const SizedBox(height: 6),
            TextFormField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              textInputAction: TextInputAction.next,
              validator: AuthValidators.validatePassword,
              autofillHints: const [AutofillHints.newPassword],
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 15,
              ),
              decoration: authFieldDecoration(
                hint: 'Choose a strong password',
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
            const SizedBox(height: 16),
            const AuthFieldLabel('Confirm password'),
            const SizedBox(height: 6),
            TextFormField(
              controller: _confirmPasswordController,
              obscureText: _obscureConfirmPassword,
              textInputAction: TextInputAction.done,
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please confirm your password';
                }
                if (value != _passwordController.text) {
                  return 'Passwords do not match';
                }
                return null;
              },
              onFieldSubmitted: (_) => _handleSignUp(),
              autofillHints: const [AutofillHints.newPassword],
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 15,
              ),
              decoration: authFieldDecoration(
                hint: 'Re-enter your password',
                icon: Icons.lock_outlined,
                suffix: IconButton(
                  splashRadius: 20,
                  icon: Icon(
                    _obscureConfirmPassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    color: AppTheme.textTertiary,
                    size: 20,
                  ),
                  onPressed: () {
                    setState(() {
                      _obscureConfirmPassword = !_obscureConfirmPassword;
                    });
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),
            const AuthFieldLabel('Referral code (optional)'),
            const SizedBox(height: 6),
            TextFormField(
              controller: _referralCodeController,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 15,
              ),
              decoration: authFieldDecoration(
                hint: 'Friend or partner gave you a code',
                icon: Icons.card_giftcard_outlined,
              ),
              validator: (value) {
                final t = value?.trim() ?? '';
                if (t.isEmpty) return null;
                if (t.length < 4) {
                  return 'At least 4 characters, or leave blank';
                }
                return null;
              },
            ),
            const SizedBox(height: 8),
            Text(
              'If you used a signup link, your code may already appear here. Clear it if you are not using a referral.',
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: AppTheme.textSecondary.withValues(alpha: 0.95),
              ),
            ),
            const SizedBox(height: 20),

            // Terms & Privacy acceptance
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                setState(() {
                  _acceptTerms = !_acceptTerms;
                });
              },
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _acceptTerms
                      ? AppTheme.primaryBlue.withOpacity(0.06)
                      : const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _acceptTerms
                        ? AppTheme.primaryBlue
                        : AppTheme.borderLight,
                    width: _acceptTerms ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: Checkbox(
                          value: _acceptTerms,
                          onChanged: (value) {
                            setState(() {
                              _acceptTerms = value ?? false;
                            });
                          },
                          activeColor: AppTheme.primaryBlue,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                          side: const BorderSide(
                            color: AppTheme.borderMedium,
                            width: 1.5,
                          ),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: RichText(
                        text: TextSpan(
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 13,
                            height: 1.5,
                          ),
                          children: [
                            const TextSpan(text: 'I accept the '),
                            TextSpan(
                              text: 'Terms of Service',
                              style: const TextStyle(
                                color: AppTheme.primaryBlue,
                                fontWeight: FontWeight.w600,
                                decoration: TextDecoration.underline,
                                decorationColor: AppTheme.primaryBlue,
                              ),
                              recognizer: TapGestureRecognizer()
                                ..onTap = () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => const TermsScreen(),
                                    ),
                                  );
                                },
                            ),
                            const TextSpan(text: ' and '),
                            TextSpan(
                              text: 'Privacy Policy',
                              style: const TextStyle(
                                color: AppTheme.primaryBlue,
                                fontWeight: FontWeight.w600,
                                decoration: TextDecoration.underline,
                                decorationColor: AppTheme.primaryBlue,
                              ),
                              recognizer: TapGestureRecognizer()
                                ..onTap = () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => const PrivacyScreen(),
                                    ),
                                  );
                                },
                            ),
                            const TextSpan(text: '.'),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            AuthGradientButton(
              label: 'Create account',
              isLoading: signupState.isLoading,
              onPressed: _handleSignUp,
            ),
            const SizedBox(height: 20),

            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'Already have an account?',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 14,
                  ),
                ),
                TextButton(
                  onPressed: () => context.go(AppRoute.login),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'Sign in',
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
    );
  }
}
