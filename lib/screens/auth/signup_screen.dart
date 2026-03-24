import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../../providers/auth_provider.dart';
import '../../services/home_button_service.dart';
import 'login_screen.dart';
import 'terms_screen.dart';
import 'privacy_screen.dart';
import '../../theme/app_theme.dart';
import '../../router/app_router.dart';
import '../../router/app_route.dart';

class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _acceptTerms = false;

  @override
  void initState() {
    super.initState();
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
    HomeButtonService.instance.show();
    super.dispose();
  }

  void _handleSignUp() async {
    if (_formKey.currentState!.validate() && _acceptTerms) {
      final email = _emailController.text.trim();
      
      try {
        await ref.read(signupStateProvider.notifier).signUp(
          name: _nameController.text.trim(),
          email: email,
          password: _passwordController.text,
        );
        
        // Navigate to email verification screen
        if (mounted) {
          context.go(AppRoute.verifyEmail, extra: email);
        }
      } catch (e) {
        // Error will be shown via signupState error handler
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
    final authState = ref.watch(authStateProvider);
    final signupState = ref.watch(signupStateProvider);
    final isMobile = MediaQuery.of(context).size.width < 600;

    // Don't auto-navigate - we'll handle navigation in _handleSignUp
    // after email verification is sent

    // Show error message if signup fails
    signupState.whenOrNull(
      error: (error, stackTrace) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showErrorSnackBar(_getErrorMessage(error));
        });
      },
    );

    return Scaffold(
      backgroundColor: AppTheme.primaryBlueDark,
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
                  'Create Account',
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
                  'Join Storage Facility Creator',
                  style: TextStyle(
                    fontSize: isMobile ? 14 : 16,
                    color: AppTheme.textOnDark.withOpacity(0.7),
                    letterSpacing: 0.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                
                Text(
                  'Start managing your storage facilities',
                  style: TextStyle(
                    fontSize: isMobile ? 12 : 14,
                    color: AppTheme.textOnDark.withOpacity(0.6),
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: isMobile ? 32 : 48),

                // Name field
                TextFormField(
                  controller: _nameController,
                  textInputAction: TextInputAction.next,
                  validator: AuthValidators.validateName,
                  style: TextStyle(color: AppTheme.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Full Name',
                    labelStyle: TextStyle(color: AppTheme.textSecondary),
                    floatingLabelBehavior: FloatingLabelBehavior.never,
                    prefixIcon: Icon(Icons.person_outlined, color: AppTheme.primaryBlue),
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
                  textInputAction: TextInputAction.next,
                  validator: AuthValidators.validatePassword,
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
                const SizedBox(height: 16),

                // Confirm Password field
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
                  style: TextStyle(color: AppTheme.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Confirm Password',
                    labelStyle: TextStyle(color: AppTheme.textSecondary),
                    floatingLabelBehavior: FloatingLabelBehavior.never,
                    prefixIcon: Icon(Icons.lock_outlined, color: AppTheme.primaryBlue),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureConfirmPassword ? Icons.visibility : Icons.visibility_off,
                        color: AppTheme.primaryBlue,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscureConfirmPassword = !_obscureConfirmPassword;
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
                const SizedBox(height: 16),

                // Terms and conditions checkbox - HIGHLY VISIBLE
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppTheme.textOnDark.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _acceptTerms ? AppTheme.success : AppTheme.textOnDark.withOpacity(0.3),
                      width: _acceptTerms ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Transform.scale(
                        scale: 1.5, // Make checkbox 50% larger for better visibility
                        child: Checkbox(
                          value: _acceptTerms,
                          onChanged: (value) {
                            setState(() {
                              _acceptTerms = value ?? false;
                            });
                          },
                          activeColor: AppTheme.success,
                          checkColor: AppTheme.textOnDark,
                          fillColor: WidgetStateProperty.resolveWith<Color>((states) {
                            if (states.contains(WidgetState.selected)) {
                              return AppTheme.success;
                            }
                            return AppTheme.textOnDark;
                          }),
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: RichText(
                          text: TextSpan(
                            style: TextStyle(
                              color: AppTheme.textOnDark,
                              fontSize: isMobile ? 14 : 16,
                              fontWeight: FontWeight.w600,
                              shadows: [
                                Shadow(
                                  offset: const Offset(0, 1),
                                  blurRadius: 2,
                                  color: AppTheme.textPrimary.withOpacity(0.3),
                                ),
                              ],
                            ),
                            children: [
                              const TextSpan(text: 'I accept the '),
                              TextSpan(
                                text: 'Terms of Service',
                                style: TextStyle(
                                  color: AppTheme.primaryBlue,
                                  decoration: TextDecoration.underline,
                                  decorationColor: AppTheme.primaryBlue,
                                ),
                                recognizer: TapGestureRecognizer()
                                  ..onTap = () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => const TermsScreen(),
                                      ),
                                    );
                                  },
                              ),
                              const TextSpan(text: ' and '),
                              TextSpan(
                                text: 'Privacy Policy',
                                style: TextStyle(
                                  color: AppTheme.primaryBlue,
                                  decoration: TextDecoration.underline,
                                  decorationColor: AppTheme.primaryBlue,
                                ),
                                recognizer: TapGestureRecognizer()
                                  ..onTap = () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => const PrivacyScreen(),
                                      ),
                                    );
                                  },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Sign up button
                ElevatedButton(
                  onPressed: signupState.isLoading ? null : _handleSignUp,
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
                  child: signupState.isLoading
                      ? SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primaryBlueDark),
                          ),
                        )
                      : Text(
                          'Create Account',
                          style: TextStyle(
                            fontSize: isMobile ? 14 : 16, 
                            fontWeight: FontWeight.w600
                          ),
                        ),
                ),
                const SizedBox(height: 24),

                // Sign in link
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Already have an account? ',
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