import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../../providers/auth_provider.dart';
import '../../services/auth_service.dart';
import '../subscription_test_screen.dart';
import '../../router/app_router.dart';
import '../../router/app_route.dart';
import '../../theme/app_theme.dart';

class EmailVerificationScreen extends ConsumerStatefulWidget {
  final String email;
  
  const EmailVerificationScreen({
    super.key,
    required this.email,
  });

  @override
  ConsumerState<EmailVerificationScreen> createState() => _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends ConsumerState<EmailVerificationScreen> {
  bool _isVerifying = false;
  bool _isResending = false;
  int _resendCooldown = 0;

  @override
  void initState() {
    super.initState();
    _checkVerificationStatus();
    // Poll for email verification every 3 seconds
    _startPolling();
  }

  void _startPolling() {
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        _checkVerificationStatus();
        _startPolling();
      }
    });
  }

  Future<void> _checkVerificationStatus() async {
    if (_isVerifying) return;
    
    setState(() {
      _isVerifying = true;
    });

    try {
      final authService = AuthService();
      final isVerified = await authService.isEmailVerified();
      
      if (isVerified) {
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          // Complete signup process
          await authService.completeSignupAfterVerification(
            email: widget.email,
            tosAccepted: true,
          );
          
          if (mounted) {
            context.go(
              AppRoute.subscription,
              extra: const SubscriptionTestScreen(
                requireSubscriptionChoice: true,
                message: 'Welcome! Please choose a subscription option to get started.',
              ),
            );
          }
        }
      }
    } catch (e) {
      if (mounted && kDebugMode) {
        print('Error checking verification status: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isVerifying = false;
        });
      }
    }
  }

  Future<void> _resendVerificationEmail() async {
    if (_resendCooldown > 0) return;
    
    setState(() {
      _isResending = true;
    });

    try {
      final authService = AuthService();
      await authService.resendVerificationEmail();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Verification email sent! Please check your inbox.'),
            backgroundColor: AppTheme.success,
          ),
        );
        
        // Set cooldown timer
        setState(() {
          _resendCooldown = 60; // 60 second cooldown
        });
        
        // Countdown timer
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted && _resendCooldown > 0) {
            setState(() {
              _resendCooldown--;
            });
            _resendCooldownTimer();
          }
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error sending email: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isResending = false;
        });
      }
    }
  }

  void _resendCooldownTimer() {
    if (_resendCooldown > 0 && mounted) {
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) {
          setState(() {
            _resendCooldown--;
          });
          _resendCooldownTimer();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    
    return Scaffold(
      backgroundColor: AppTheme.primaryBlueDark,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(isMobile ? 24.0 : 32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: isMobile ? 40 : 80),
              
              // Email icon
              Container(
                padding: EdgeInsets.all(isMobile ? 20 : 24),
                decoration: BoxDecoration(
                  color: AppTheme.textOnDark.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.mark_email_read,
                  size: isMobile ? 64 : 80,
                  color: AppTheme.textOnDark,
                ),
              ),
              SizedBox(height: isMobile ? 32 : 48),
              
              Text(
                'Verify Your Email',
                style: TextStyle(
                  fontSize: isMobile ? 28 : 32,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textOnDark,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              
              Text(
                'We sent a verification email to:',
                style: TextStyle(
                  fontSize: isMobile ? 14 : 16,
                  color: AppTheme.textOnDark.withOpacity(0.7),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.textOnDark.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  widget.email,
                  style: TextStyle(
                    fontSize: isMobile ? 14 : 16,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textOnDark,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 24),
              
              Text(
                'Please check your inbox and click the verification link to continue.',
                style: TextStyle(
                  fontSize: isMobile ? 14 : 16,
                  color: AppTheme.textOnDark.withOpacity(0.7),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              
              // Verification status
              if (_isVerifying)
                Column(
                  children: [
                    CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(AppTheme.textOnDark),
                    ),
                    SizedBox(height: 16),
                    Text(
                      'Checking verification status...',
                      style: TextStyle(
                        color: AppTheme.textOnDark.withOpacity(0.7),
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              
              const SizedBox(height: 32),
              
              // Resend button
              OutlinedButton.icon(
                onPressed: _resendCooldown > 0 || _isResending ? null : _resendVerificationEmail,
                icon: _isResending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: Text(
                  _resendCooldown > 0
                      ? 'Resend in ${_resendCooldown}s'
                      : 'Resend Verification Email',
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textOnDark,
                  side: BorderSide(color: AppTheme.textOnDark),
                  padding: EdgeInsets.symmetric(
                    vertical: isMobile ? 12 : 16,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              
              // Manual refresh button
              ElevatedButton.icon(
                onPressed: _isVerifying ? null : _checkVerificationStatus,
                icon: _isVerifying
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_circle),
                label: const Text('I\'ve Verified My Email'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.surface,
                  foregroundColor: AppTheme.primaryBlueDark,
                  padding: EdgeInsets.symmetric(
                    vertical: isMobile ? 12 : 16,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              SizedBox(height: isMobile ? 40 : 80),
            ],
          ),
        ),
      ),
    );
  }
}

