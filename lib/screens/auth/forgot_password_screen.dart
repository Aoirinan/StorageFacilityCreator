import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../../providers/auth_provider.dart';
import '../../services/home_button_service.dart';
import '../../theme/app_theme.dart';
import '../../router/app_route.dart';
import 'widgets/auth_shell.dart';

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  bool _isEmailSent = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      HomeButtonService.instance.hide();
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    HomeButtonService.instance.show();
    super.dispose();
  }

  void _handleResetPassword() async {
    final valid = _formKey.currentState!.validate();
    if (valid) {
      await ref.read(forgotPasswordStateProvider.notifier).resetPassword(
            email: _emailController.text.trim(),
          );
      if (!mounted) return;
      final result = ref.read(forgotPasswordStateProvider);
      if (result.hasError) {
        _showErrorSnackBar(_getErrorMessage(result.error));
      } else {
        setState(() {
          _isEmailSent = true;
        });
        _showSuccessSnackBar('Password reset email sent! Check your inbox.');
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

  void _showSuccessSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppTheme.success,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _getErrorMessage(dynamic error) {
    if (error is FirebaseAuthException) {
      switch (error.code) {
        case 'user-not-found':
          return 'No account found with this email address.';
        case 'invalid-email':
          return 'Please enter a valid email address.';
        case 'too-many-requests':
          return 'Too many requests. Please try again later.';
        default:
          return error.message ??
              'An error occurred while sending reset email.';
      }
    }
    return 'An unexpected error occurred.';
  }

  @override
  Widget build(BuildContext context) {
    final forgotPasswordState = ref.watch(forgotPasswordStateProvider);

    // Success/error handling happens in _handleResetPassword after the call
    // completes. Do not react to the provider state during build: the shared
    // notifier's initial/stale state is AsyncData(null), which previously made
    // the screen show "email sent" before the user submitted anything.

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
            AuthLogoHeader(
              title: _isEmailSent ? 'Check your email' : 'Reset password',
              subtitle: _isEmailSent
                  ? 'We sent a reset link to the email below. It should arrive within a few minutes.'
                  : 'Enter the email on your account and we will send you a link to reset your password.',
            ),
            if (!_isEmailSent) ...[
              const AuthFieldLabel('Email'),
              const SizedBox(height: 6),
              TextFormField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.done,
                validator: AuthValidators.validateEmail,
                autofillHints: const [AutofillHints.email],
                onFieldSubmitted: (_) => _handleResetPassword(),
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 15,
                ),
                decoration: authFieldDecoration(
                  hint: 'you@company.com',
                  icon: Icons.email_outlined,
                ),
              ),
              const SizedBox(height: 20),
              AuthGradientButton(
                label: 'Send reset email',
                isLoading: forgotPasswordState.isLoading,
                onPressed: _handleResetPassword,
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'Remember your password?',
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
            ] else ...[
              // Sent state: show email as read-only + success chip + resend + back
              const AuthFieldLabel('Email'),
              const SizedBox(height: 6),
              TextFormField(
                controller: _emailController,
                enabled: false,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 15,
                ),
                decoration: authFieldDecoration(
                  hint: '',
                  icon: Icons.email_outlined,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.success.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppTheme.success.withOpacity(0.25),
                    width: 1,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.check_circle_rounded,
                      color: AppTheme.success,
                      size: 22,
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Reset email sent. If you do not see it in a few minutes, check your spam folder or resend below.',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              AuthGradientButton(
                label: 'Resend reset email',
                isLoading: forgotPasswordState.isLoading,
                onPressed: _handleResetPassword,
              ),
              const SizedBox(height: 12),
              AuthOutlinedButton(
                icon: Icons.arrow_back,
                label: 'Back to sign in',
                onPressed: () => context.go(AppRoute.login),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
