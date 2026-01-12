import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../../providers/auth_provider.dart';
import 'login_screen.dart';
import '../../services/home_button_service.dart';
import '../../theme/app_theme.dart';
import '../../router/app_router.dart';
import '../../router/app_route.dart';

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  ConsumerState<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
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
    if (_formKey.currentState!.validate()) {
      await ref.read(forgotPasswordStateProvider.notifier).resetPassword(
        email: _emailController.text.trim(),
      );
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
          return error.message ?? 'An error occurred while sending reset email.';
      }
    }
    return 'An unexpected error occurred.';
  }

  @override
  Widget build(BuildContext context) {
    final forgotPasswordState = ref.watch(forgotPasswordStateProvider);
    final isMobile = MediaQuery.of(context).size.width < 600;

    // Show success message if email is sent
    forgotPasswordState.whenOrNull(
      data: (data) {
        if (!_isEmailSent) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            setState(() {
              _isEmailSent = true;
            });
            _showSuccessSnackBar('Password reset email sent! Check your inbox.');
          });
        }
      },
      error: (error, stackTrace) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showErrorSnackBar(_getErrorMessage(error));
        });
      },
    );

    return Scaffold(
      backgroundColor: AppTheme.primaryBlueDark,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppTheme.textOnDark),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(isMobile ? 16.0 : 24.0),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: isMobile ? 20 : 40),
                
                // Icon and title - responsive sizing
                Container(
                  padding: EdgeInsets.all(isMobile ? 16 : 20),
                  decoration: BoxDecoration(
                    color: AppTheme.textOnDark.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(
                    Icons.lock_reset,
                    size: isMobile ? 64 : 100,
                    color: AppTheme.textOnDark,
                  ),
                ),
                SizedBox(height: isMobile ? 24 : 40),
                
                Text(
                  'Reset Password',
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
                  'Enter your email address',
                  style: TextStyle(
                    fontSize: isMobile ? 14 : 16,
                    color: AppTheme.textOnDark.withOpacity(0.7),
                    letterSpacing: 0.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                
                Text(
                  'We\'ll send you a link to reset your password',
                  style: TextStyle(
                    fontSize: isMobile ? 12 : 14,
                    color: AppTheme.textOnDark.withOpacity(0.6),
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: isMobile ? 32 : 48),

                if (!_isEmailSent) ...[
                  // Email field
                  TextFormField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.done,
                    validator: AuthValidators.validateEmail,
                    onFieldSubmitted: (_) => _handleResetPassword(),
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
                  const SizedBox(height: 24),

                  // Send reset email button
                  ElevatedButton(
                    onPressed: forgotPasswordState.isLoading ? null : _handleResetPassword,
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
                    child: forgotPasswordState.isLoading
                        ? SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primaryBlueDark),
                            ),
                          )
                        : Text(
                            'Send Reset Email',
                            style: TextStyle(
                              fontSize: isMobile ? 14 : 16, 
                              fontWeight: FontWeight.w600
                            ),
                          ),
                  ),
                ] else ...[
                  // Entered email (read-only)
                  TextFormField(
                    controller: _emailController,
                    enabled: false,
                    decoration: InputDecoration(
                      labelText: 'Email',
                      labelStyle: TextStyle(color: AppTheme.textSecondary),
                      prefixIcon: Icon(Icons.email_outlined, color: AppTheme.textOnDark.withOpacity(0.7)),
                      filled: true,
                      fillColor: AppTheme.textOnDark.withOpacity(0.15),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: AppTheme.textOnDark.withOpacity(0.3)),
                      ),
                      disabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: AppTheme.textOnDark.withOpacity(0.3)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: forgotPasswordState.isLoading ? null : _handleResetPassword,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.surface,
                      foregroundColor: AppTheme.primaryBlueDark,
                      padding: EdgeInsets.symmetric(
                        vertical: isMobile ? 12 : 16,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 2,
                    ),
                    child: forgotPasswordState.isLoading
                        ? SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primaryBlueDark),
                            ),
                          )
                        : Text(
                            'Resend Reset Email',
                            style: TextStyle(
                              fontSize: isMobile ? 14 : 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                  const SizedBox(height: 16),
                  // Success state
                  Container(
                    padding: EdgeInsets.all(isMobile ? 20 : 24),
                    decoration: BoxDecoration(
                      color: AppTheme.success.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppTheme.success.withOpacity(0.3)),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          Icons.check_circle,
                          color: AppTheme.success,
                          size: isMobile ? 48 : 64,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Email Sent!',
                          style: TextStyle(
                            fontSize: isMobile ? 18 : 20,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.success,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Check your email for password reset instructions.',
                          style: TextStyle(
                            fontSize: isMobile ? 12 : 14,
                            color: AppTheme.textOnDark.withOpacity(0.7),
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Back to login button
                  OutlinedButton(
                    onPressed: () => context.go(AppRoute.login),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.textOnDark,
                      side: BorderSide(color: AppTheme.textOnDark),
                      padding: EdgeInsets.symmetric(
                        vertical: isMobile ? 12 : 16
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      'Back to Sign In',
                      style: TextStyle(
                        fontSize: isMobile ? 14 : 16, 
                        fontWeight: FontWeight.w600
                      ),
                    ),
                  ),
                  const SizedBox(height: 120),
                ],
                
                const SizedBox(height: 24),
                
                // Back to login link
                if (!_isEmailSent)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Remember your password? ',
                        style: TextStyle(
                          color: AppTheme.textOnDark.withOpacity(0.7),
                          fontSize: isMobile ? 12 : 14,
                        ),
                      ),
                      TextButton(
                        onPressed: () => context.go(AppRoute.login),
                        child: Text(
                          'Sign In',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textOnDark,
                            fontSize: isMobile ? 12 : 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                
                SizedBox(height: isMobile ? 20 : 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}