import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../../providers/auth_provider.dart';
import 'signup_screen.dart';
import 'forgot_password_screen.dart';
import '../home_screen_modern.dart';
import '../tenant_portal_access_screen.dart';
import '../../router/app_router.dart';
import '../../router/app_route.dart';
import '../../services/home_button_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/language_selector.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

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
    _passwordController.dispose();
    HomeButtonService.instance.show();
    super.dispose();
  }

  void _handleSignIn() async {
    if (_formKey.currentState!.validate()) {
      await ref.read(loginStateProvider.notifier).signIn(
        email: _emailController.text.trim(),
        password: _passwordController.text,
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

    // Navigate to home if user is authenticated
    authState.whenData((user) {
      if (user != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) {
            context.go(AppRoute.dashboard);
          }
        });
      }
    });

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