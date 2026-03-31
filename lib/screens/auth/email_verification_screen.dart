import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../../services/auth_service.dart';
import '../subscription_test_screen.dart';
import '../../router/app_route.dart';
import '../../theme/app_theme.dart';

class EmailVerificationScreen extends ConsumerStatefulWidget {
  final String email;

  const EmailVerificationScreen({
    super.key,
    required this.email,
  });

  @override
  ConsumerState<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends ConsumerState<EmailVerificationScreen> {
  bool _manualCheckBusy = false;
  bool _isResending = false;
  int _resendCooldown = 0;
  Timer? _pollingTimer;
  bool _pollInFlight = false;
  DateTime? _lastSilentCheck;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkVerification(showLoadingUi: true);
    });
    _pollingTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) _checkVerification(showLoadingUi: false);
    });
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkVerification({required bool showLoadingUi}) async {
    if (_pollInFlight) return;
    _pollInFlight = true;
    if (showLoadingUi && mounted) {
      setState(() => _manualCheckBusy = true);
    }
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      await user.reload();
      final refreshed = FirebaseAuth.instance.currentUser;
      if (refreshed == null) return;

      if (mounted) {
        setState(() => _lastSilentCheck = DateTime.now());
      }

      if (!refreshed.emailVerified) return;

      final authService = AuthService();
      try {
        await authService.completeSignupAfterVerification(
          email: widget.email,
          tosAccepted: true,
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Email verified, but setup failed: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
        return;
      }

      if (mounted) {
        context.go(
          AppRoute.subscription,
          extra: const SubscriptionTestScreen(
            requireSubscriptionChoice: true,
            message:
                'Welcome! Please choose a subscription option to get started.',
          ),
        );
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error checking verification status: $e');
      }
      if (mounted && showLoadingUi) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not check verification: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      _pollInFlight = false;
      if (showLoadingUi && mounted) {
        setState(() => _manualCheckBusy = false);
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
            content: Text(
              'Verification email sent. Older links from previous emails will stop working — use this newest one.',
            ),
            backgroundColor: AppTheme.success,
          ),
        );

        setState(() {
          _resendCooldown = 60;
        });
        _resendCooldownTimer();
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
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.textOnDark.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppTheme.textOnDark.withOpacity(0.2),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info_outline,
                            size: 18, color: AppTheme.textOnDark),
                        const SizedBox(width: 8),
                        Text(
                          'Tips',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textOnDark,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '• Check Spam or Promotions in Gmail. Tap “Report not spam” so future messages land in your inbox.\n'
                      '• If you tap Resend, only the newest email’s link works; older links show “expired or already used.”\n'
                      '• Open the verification link once; wait until you see success from Firebase, then return here.',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.45,
                        color: AppTheme.textOnDark.withOpacity(0.85),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Please check your inbox and click the verification link to continue.',
                style: TextStyle(
                  fontSize: isMobile ? 14 : 16,
                  color: AppTheme.textOnDark.withOpacity(0.7),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              if (_manualCheckBusy)
                Column(
                  children: [
                    CircularProgressIndicator(
                      valueColor:
                          AlwaysStoppedAnimation<Color>(AppTheme.textOnDark),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Checking…',
                      style: TextStyle(
                        color: AppTheme.textOnDark.withOpacity(0.7),
                        fontSize: 14,
                      ),
                    ),
                  ],
                )
              else
                Text(
                  _lastSilentCheck == null
                      ? 'We also check automatically every 15 seconds (this page stays still — no need to refresh).'
                      : 'Last automatic check: ${_formatTime(_lastSilentCheck!)} · next in the background.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textOnDark.withOpacity(0.55),
                  ),
                ),
              const SizedBox(height: 28),
              OutlinedButton.icon(
                onPressed: _resendCooldown > 0 || _isResending
                    ? null
                    : _resendVerificationEmail,
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
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _manualCheckBusy
                    ? null
                    : () => _checkVerification(showLoadingUi: true),
                icon: _manualCheckBusy
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

  String _formatTime(DateTime t) {
    final h = t.hour > 12 ? t.hour - 12 : (t.hour == 0 ? 12 : t.hour);
    final am = t.hour >= 12 ? 'PM' : 'AM';
    return '$h:${t.minute.toString().padLeft(2, '0')} $am';
  }
}
