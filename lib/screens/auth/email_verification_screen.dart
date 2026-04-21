import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../../services/auth_service.dart';
import '../../router/app_route.dart';
import '../../theme/app_theme.dart';
import 'widgets/auth_shell.dart';

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

  /// Falls back to the currently signed-in Firebase user's email when
  /// `widget.email` is empty (e.g. user landed on /verify-email directly
  /// via the browser URL instead of coming from signup/login).
  String get _effectiveEmail {
    if (widget.email.trim().isNotEmpty) return widget.email.trim();
    return FirebaseAuth.instance.currentUser?.email ?? '';
  }

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
          email: _effectiveEmail,
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
        // Let route guards/subscription checks send the user to the correct
        // destination (dashboard, pending approval, or subscription) without
        // duplicating routing rules here.
        context.go(AppRoute.dashboard);
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

  Future<void> _backToSignIn() async {
    _pollingTimer?.cancel();
    try {
      await AuthService().signOut();
    } catch (_) {
      // If sign-out fails, still try to navigate away so the user isn't stuck.
    }
    if (!mounted) return;
    context.go(AppRoute.login);
  }

  @override
  Widget build(BuildContext context) {
    return AuthShell(
      backButton: AuthShellBackButton(onPressed: _backToSignIn),
      belowCard: Center(
        child: AuthSecondaryLink(
          icon: Icons.arrow_back,
          label: 'Back to sign in',
          onPressed: _backToSignIn,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppTheme.primaryBlue, AppTheme.primaryBlueLight],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.primaryBlue.withOpacity(0.3),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: const Icon(
                Icons.mark_email_read,
                size: 36,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Verify your email',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: AppTheme.textPrimary,
              letterSpacing: -0.5,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _effectiveEmail.isEmpty
                ? 'A verification link was sent to your inbox.'
                : 'We sent a verification link to:',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14,
              color: AppTheme.textSecondary,
              height: 1.5,
            ),
          ),
          if (_effectiveEmail.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppTheme.primaryBlue.withOpacity(0.15),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.email_outlined,
                    size: 16,
                    color: AppTheme.primaryBlue,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _effectiveEmail,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFBEB),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFFFDE68A),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.lightbulb_outline,
                      size: 16,
                      color: Color(0xFFB45309),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Tips',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF92400E),
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  '• Check Spam or Promotions in Gmail. Tap “Report not spam” so future messages land in your inbox.\n'
                  '• If you tap Resend, only the newest link works; older links show “expired or already used.”\n'
                  '• Open the link once and wait for the Firebase success page, then come back here.',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: Color(0xFF713F12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _StatusRow(
            busy: _manualCheckBusy,
            lastCheck: _lastSilentCheck,
          ),
          const SizedBox(height: 20),
          AuthGradientButton(
            isLoading: _manualCheckBusy,
            onPressed: () => _checkVerification(showLoadingUi: true),
            label: "I've verified my email",
          ),
          const SizedBox(height: 12),
          AuthOutlinedButton(
            onPressed: _resendCooldown > 0 || _isResending
                ? null
                : _resendVerificationEmail,
            icon: _isResending ? null : Icons.refresh,
            label: _isResending
                ? 'Sending…'
                : (_resendCooldown > 0
                    ? 'Resend in ${_resendCooldown}s'
                    : 'Resend verification email'),
          ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final bool busy;
  final DateTime? lastCheck;

  const _StatusRow({required this.busy, required this.lastCheck});

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primaryBlue),
            ),
          ),
          SizedBox(width: 10),
          Text(
            'Checking…',
            style: TextStyle(
              fontSize: 12.5,
              color: AppTheme.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: AppTheme.primaryBlue.withOpacity(0.5),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            lastCheck == null
                ? 'We check automatically every 15 seconds — no need to refresh.'
                : 'Last check: ${_formatTime(lastCheck!)} · next in the background.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              color: AppTheme.textTertiary,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }

  static String _formatTime(DateTime t) {
    final h = t.hour > 12 ? t.hour - 12 : (t.hour == 0 ? 12 : t.hour);
    final am = t.hour >= 12 ? 'PM' : 'AM';
    return '$h:${t.minute.toString().padLeft(2, '0')} $am';
  }
}
