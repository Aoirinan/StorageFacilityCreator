import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../services/permission_service.dart';
import '../services/facility_service.dart';
import '../router/app_route.dart';
import '../theme/app_theme.dart';

class AcceptInviteScreen extends StatefulWidget {
  final String facilityId;
  final String inviteId;

  const AcceptInviteScreen({
    Key? key,
    required this.facilityId,
    required this.inviteId,
  }) : super(key: key);

  @override
  State<AcceptInviteScreen> createState() => _AcceptInviteScreenState();
}

class _AcceptInviteScreenState extends State<AcceptInviteScreen> {
  bool _isLoading = true;
  bool _isProcessing = false;
  bool _hasTriedAutoAccept = false;
  String? _errorMessage;
  String? _facilityName;
  String? _roleType;
  String? _invitedByEmail;
  /// Email the invitation was sent to (for "Log in with invited email" when mismatch)
  String? _inviteeEmail;
  /// Email the invite was sent to (for login/signup deep links).
  String? _inviteEmail;

  StreamSubscription<User?>? _authSubscription;

  @override
  void initState() {
    super.initState();
    print('🔗 [AcceptInviteScreen] Initialized with facilityId: ${widget.facilityId}, inviteId: ${widget.inviteId}');
    _loadInvite();

    // One listener per screen instance; must cancel on dispose so we do not run after leaving this route.
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (!mounted) return;
      if (user != null && !_isProcessing && !_isLoading && !_hasTriedAutoAccept) {
        print('👤 [AcceptInviteScreen] User logged in, attempting to fulfill invite');
        _hasTriedAutoAccept = true;
        _acceptInvite();
      }
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadInvite() async {
    print('📥 [AcceptInviteScreen] Loading invite...');
    try {
      final invite = await PermissionService.getFacilityInviteById(
        facilityId: widget.facilityId,
        inviteId: widget.inviteId,
      );
      if (invite == null) {
        print('📋 [AcceptInviteScreen] Invite document not found or not readable');
        setState(() {
          _errorMessage =
              'This invitation was not found. It may have been cancelled, the link may be wrong, or the facility ID in the link does not match.';
          _isLoading = false;
        });
        return;
      }
      print('✅ [AcceptInviteScreen] Found invite: ${invite.email}, status: ${invite.status}');

      if (!invite.isPending) {
        print('⚠️ [AcceptInviteScreen] Invite is not pending');
        setState(() {
          _errorMessage = 'This invitation has already been accepted or cancelled.';
          _isLoading = false;
        });
        return;
      }

      // Get facility name
      final facility = await FacilityService.getFacility(widget.facilityId);
      
      // Get role display name
      final role = PermissionService.getRoleByType(invite.roleType);

      setState(() {
        _facilityName = facility?.name ?? 'Unknown Facility';
        _roleType = role?.name ?? invite.roleType.name;
        _invitedByEmail = invite.invitedByEmail;
        _inviteEmail = invite.email;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Error loading invitation: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _acceptInvite() async {
    print('🔘 [AcceptInviteScreen] Accept button clicked');
    final user = FirebaseAuth.instance.currentUser;
    print('👤 [AcceptInviteScreen] Current user: ${user?.email ?? "null"}');
    if (user == null) {
      print('🔐 [AcceptInviteScreen] User not logged in, redirecting to login');
      try {
        final invite = await PermissionService.getFacilityInviteById(
          facilityId: widget.facilityId,
          inviteId: widget.inviteId,
        );
        if (invite == null) {
          throw Exception('Invitation not found');
        }

        final redirectUrl = '${AppRoute.acceptInvite}?facilityId=${widget.facilityId}&inviteId=${widget.inviteId}';

        if (mounted) {
          context.go(
            '${AppRoute.login}?email=${Uri.encodeComponent(invite.email)}&redirect=${Uri.encodeComponent(redirectUrl)}',
          );
        }
      } catch (e) {
        setState(() {
          _errorMessage = 'Error: $e. Please try logging in first.';
        });
        if (mounted) {
          context.go('${AppRoute.login}?redirect=${Uri.encodeComponent(GoRouterState.of(context).uri.toString())}');
        }
      }
      return;
    }

    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      print('✅ [AcceptInviteScreen] User is logged in, fulfilling invite...');

      final invite = await PermissionService.getFacilityInviteById(
        facilityId: widget.facilityId,
        inviteId: widget.inviteId,
      );
      if (invite == null) {
        throw Exception(
          'Invitation not found. It may have been cancelled or the link is invalid.',
        );
      }

      print('📧 [AcceptInviteScreen] Invite email: ${invite.email}, User email: ${user.email}');
      
      // Check if email matches (case-insensitive)
      if (invite.email.toLowerCase() != user.email?.toLowerCase()) {
        setState(() {
          _inviteeEmail = invite.email;
          _errorMessage = 'This invitation was sent to ${invite.email}, but you are logged in as ${user.email}. Please log in with the correct email address.';
          _isProcessing = false;
        });
        return;
      }
      
      // Fulfill ONLY this specific invite, not all pending invites
      // This prevents auto-accepting other pending invites when user accepts one
      print('🔄 [AcceptInviteScreen] Fulfilling specific invite: ${widget.inviteId}...');
      final fulfilled = await PermissionService.fulfillSpecificInvite(
        facilityId: widget.facilityId,
        inviteId: widget.inviteId,
        userId: user.uid,
        displayName: user.displayName,
        email: user.email,
      );
      
      if (!fulfilled) {
        throw Exception('Failed to accept invitation. The invite may have already been accepted or cancelled.');
      }

      FacilityService.clearFacilitiesCache();
      
      print('✅ [AcceptInviteScreen] Invite fulfilled successfully');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Invitation accepted! You now have access to this facility.'),
            backgroundColor: AppTheme.success,
            duration: Duration(seconds: 3),
          ),
        );
        // Wait a moment before redirecting so user can see the success message
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) {
          context.go(AppRoute.dashboard);
        }
      }
    } catch (e, stackTrace) {
      print('❌ [AcceptInviteScreen] Error accepting invitation: $e');
      print('❌ [AcceptInviteScreen] Stack trace: $stackTrace');
      setState(() {
        _errorMessage = 'Error accepting invitation: $e';
        _isProcessing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundLight,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: Card(
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _errorMessage != null && _facilityName == null
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.error_outline,
                                  size: 64,
                                  color: AppTheme.error,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  _errorMessage!,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    color: AppTheme.error,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 24),
                                ElevatedButton(
                                  onPressed: () => context.go(AppRoute.login),
                                  child: const Text('Go to Login'),
                                ),
                              ],
                            )
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Icon(
                                  Icons.mail_outline,
                                  size: 64,
                                  color: AppTheme.primaryBlue,
                                ),
                                const SizedBox(height: 24),
                                const Text(
                                  'Facility Invitation',
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  'You\'ve been invited to join',
                                  style: TextStyle(
                                    fontSize: 16,
                                    color: AppTheme.textSecondary,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _facilityName ?? 'Unknown Facility',
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: AppTheme.primaryBlue,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'as a $_roleType',
                                  style: TextStyle(
                                    fontSize: 16,
                                    color: AppTheme.textSecondary,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                if (_invitedByEmail != null) ...[
                                  const SizedBox(height: 16),
                                  Text(
                                    'Invited by: $_invitedByEmail',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: AppTheme.textSecondary,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                                const SizedBox(height: 32),
                                if (FirebaseAuth.instance.currentUser == null &&
                                    _inviteEmail != null) ...[
                                  Text(
                                    'If you\'re not signed in yet, Accept will open the sign-in page. '
                                    'New to SFC? Tap Sign up there—the invited email stays filled in.',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.textSecondary,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 16),
                                ],
                                if (_errorMessage != null)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 16),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          _errorMessage!,
                                          style: const TextStyle(
                                            color: AppTheme.error,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                        if (_inviteeEmail != null) ...[
                                          const SizedBox(height: 16),
                                          OutlinedButton.icon(
                                            onPressed: () async {
                                              await FirebaseAuth.instance.signOut();
                                              if (!mounted) return;
                                              final redirect = '${AppRoute.acceptInvite}?facilityId=${widget.facilityId}&inviteId=${widget.inviteId}';
                                              context.go('${AppRoute.login}?email=${Uri.encodeComponent(_inviteeEmail!)}&redirect=${Uri.encodeComponent(redirect)}');
                                            },
                                            icon: const Icon(Icons.login, size: 20),
                                            label: const Text('Log in with invited email'),
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor: AppTheme.primaryBlue,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ElevatedButton(
                                  onPressed: (_isProcessing || _isLoading) ? null : () {
                                    print('🔘 [AcceptInviteScreen] Button onPressed called');
                                    _acceptInvite();
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppTheme.primaryBlue,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(vertical: 16),
                                    minimumSize: const Size(double.infinity, 50),
                                  ),
                                  child: _isProcessing
                                      ? const SizedBox(
                                          height: 20,
                                          width: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                          ),
                                        )
                                      : const Text(
                                          'Accept Invitation',
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                          ),
                                        ),
                                ),
                                const SizedBox(height: 12),
                                TextButton(
                                  onPressed: () {
                                    final redirect =
                                        '${AppRoute.acceptInvite}?facilityId=${widget.facilityId}&inviteId=${widget.inviteId}';
                                    final email = _inviteEmail;
                                    if (email != null && email.isNotEmpty) {
                                      context.go(
                                        '${AppRoute.login}?email=${Uri.encodeComponent(email)}&redirect=${Uri.encodeComponent(redirect)}',
                                      );
                                    } else {
                                      context.go(
                                        '${AppRoute.login}?redirect=${Uri.encodeComponent(redirect)}',
                                      );
                                    }
                                  },
                                  child: const Text('Already have an account? Log in'),
                                ),
                              ],
                            ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

