import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:convert';
import '../models/permission_model.dart';
import '../models/facility_model.dart';
import '../services/permission_service.dart';
import '../services/facility_service.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';

// #region agent log
void _debugLogPMS(String location, String message, Map<String, dynamic> data, String hypothesisId) {
  final logEntry = jsonEncode({
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    'location': location,
    'message': message,
    'data': data,
    'sessionId': 'debug-session',
    'runId': 'run1',
    'hypothesisId': hypothesisId,
  });
  // Always print for immediate visibility (works on web and desktop)
  print('[DEBUG] $logEntry');
}
// #endregion

class PermissionManagementScreen extends ConsumerStatefulWidget {
  const PermissionManagementScreen({super.key});

  @override
  ConsumerState<PermissionManagementScreen> createState() => _PermissionManagementScreenState();
}

class _PermissionManagementScreenState extends ConsumerState<PermissionManagementScreen>
    with TickerProviderStateMixin {
  late TabController _tabController;
  String? _selectedFacilityId;
  List<UserRole> _facilityUsers = [];
  List<FacilityModel> _facilities = [];
  Map<String, Map<String, dynamic>> _userProfiles = {};
  List<FacilityInvite> _pendingInvites = [];
  bool _isLoading = false;

  @override
  void initState() {
    // #region agent log
    _debugLogPMS('permission_management_screen.dart:30', 'PermissionManagementScreen initState called', {}, 'D');
    // #endregion
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    // #region agent log
    _debugLogPMS('permission_management_screen.dart:34', 'TabController created, calling _loadFacilities', {}, 'D');
    // #endregion
    _loadFacilities();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadFacilities() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final facilities = await FacilityService.getUserFacilities();
      if (!mounted) return;
      setState(() {
        _facilities = facilities;
        if (facilities.isNotEmpty) {
          _selectedFacilityId ??= facilities.first.id;
        }
      });
      if (_selectedFacilityId != null) {
        await _loadFacilityUsers();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading facilities: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _loadFacilityUsers() async {
    if (_selectedFacilityId == null || !mounted) return;
    
    setState(() => _isLoading = true);
    try {
      final users = await PermissionService.getFacilityUsers(_selectedFacilityId!);
      users.sort((a, b) {
        final levelA = PermissionService.getRoleByType(a.roleType)?.level ?? 0;
        final levelB = PermissionService.getRoleByType(b.roleType)?.level ?? 0;
        if (levelA == levelB) {
          return b.assignedAt.compareTo(a.assignedAt);
        }
        return levelB.compareTo(levelA);
      });

      final profileEntries = await Future.wait(users.map((user) async {
        final profile = await PermissionService.getUserProfile(user.userId);
        return MapEntry(user.userId, profile);
      }));
      final invites = await PermissionService.getFacilityInvites(_selectedFacilityId!);

      if (!mounted) return;

      final profiles = <String, Map<String, dynamic>>{};
      for (final entry in profileEntries) {
        final profile = entry.value;
        if (profile != null) {
          profiles[entry.key] = profile;
        }
      }

      setState(() {
        _facilityUsers = users;
        _userProfiles = profiles;
        _pendingInvites = invites;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading users: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // #region agent log
    _debugLogPMS('permission_management_screen.dart:120', 'PermissionManagementScreen build called', {'mounted': mounted, 'hasFacilities': _facilities.isNotEmpty, 'selectedFacilityId': _selectedFacilityId}, 'D');
    // #endregion
    return ModernPageWrapper(
      title: 'Permission Management',
      currentRoute: '/permissions',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      child: Column(
        children: [
          // Facility selector
          Container(
            padding: const EdgeInsets.all(16),
            color: AppTheme.backgroundLight,
            child: Row(
              children: [
                Icon(Icons.business, color: AppTheme.primaryBlue),
                const SizedBox(width: 8),
                Text(
                  'Facility:',
                  style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _facilities.isEmpty
                      ? Text(
                          'No facilities found',
                          style: TextStyle(color: AppTheme.textSecondary),
                        )
                      : DropdownButton<String>(
                          value: _selectedFacilityId,
                          isExpanded: true,
                          dropdownColor: AppTheme.surface,
                          style: TextStyle(color: AppTheme.textPrimary),
                          items: _facilities.map((facility) {
                            return DropdownMenuItem<String>(
                              value: facility.id,
                              child: Text(facility.name),
                            );
                          }).toList(),
                          onChanged: (String? newValue) {
                            if (newValue != null && newValue != _selectedFacilityId) {
                              setState(() {
                                _selectedFacilityId = newValue;
                              });
                              _loadFacilityUsers();
                            }
                          },
                        ),
                ),
              ],
            ),
          ),
          // Tab bar
          Container(
            color: AppTheme.surface,
            child: TabBar(
              controller: _tabController,
              indicatorColor: AppTheme.primaryBlue,
              labelColor: AppTheme.primaryBlue,
              unselectedLabelColor: AppTheme.textSecondary,
              tabs: const [
                Tab(icon: Icon(Icons.people), text: 'Users'),
                Tab(icon: Icon(Icons.security), text: 'Roles'),
                Tab(icon: Icon(Icons.settings), text: 'Settings'),
              ],
            ),
          ),
          // Tab content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildUsersTab(),
                _buildRolesTab(),
                _buildSettingsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUsersTab() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_selectedFacilityId == null) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.business, size: 64, color: AppTheme.textTertiary),
            SizedBox(height: 16),
            Text(
              'No facility selected',
              style: TextStyle(fontSize: 18, color: AppTheme.textTertiary),
            ),
            SizedBox(height: 8),
            Text(
              'Please select a facility to manage permissions',
              style: TextStyle(color: AppTheme.textTertiary),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final pendingInvites =
        _pendingInvites.where((invite) => invite.isPending).toList();

    final children = <Widget>[];

    if (_facilityUsers.isEmpty) {
      children.add(
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.group_add, size: 40, color: AppTheme.textTertiary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'No team members yet',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Use “Add User to Facility” to invite teammates. Pending invitations will appear below.',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: AppTheme.textSecondary),
                ),
              ],
            ),
          ),
        ),
      );
    } else {
      for (final userRole in _facilityUsers) {
        final role = PermissionService.getRoleByType(userRole.roleType);
        final profile = _userProfiles[userRole.userId];
        final email = profile?['email'] ?? 'Unknown email';
        final displayName = profile?['displayName'] ?? email;

        children.add(
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: role?.color.withOpacity(0.1),
                child: Icon(
                  _getRoleIcon(userRole.roleType),
                  color: role?.color,
                ),
              ),
              title: Text(displayName),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(email, style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      Chip(
                        label: Text(role?.name ?? userRole.roleType.displayName),
                        backgroundColor: role?.color.withOpacity(0.1),
                        labelStyle:
                            TextStyle(color: role?.color ?? AppTheme.textSecondary),
                      ),
                      Chip(
                        label: Text('Assigned ${_formatDate(userRole.assignedAt)}'),
                        backgroundColor: AppTheme.backgroundLight,
                      ),
                      if (userRole.expiresAt != null)
                        Chip(
                          label: Text('Expires ${_formatDate(userRole.expiresAt!)}'),
                          backgroundColor: AppTheme.warning.withOpacity(0.1),
                          labelStyle: TextStyle(color: AppTheme.warning),
                        ),
                    ],
                  ),
                ],
              ),
              trailing: PopupMenuButton<String>(
                onSelected: (value) => _handleUserAction(value, userRole),
                itemBuilder: (context) {
                  final currentUser = FirebaseAuth.instance.currentUser;
                  final isOwner = _selectedFacilityId != null && 
                      _facilities.firstWhere(
                        (f) => f.id == _selectedFacilityId,
                        orElse: () => _facilities.first,
                      ).ownerUid == userRole.userId;
                  final isCurrentUser = currentUser?.uid == userRole.userId;
                  
                  return [
                    PopupMenuItem(
                      value: 'change_role',
                      enabled: !isOwner || isCurrentUser, // Can't change owner role unless it's yourself
                      child: ListTile(
                        leading: Icon(Icons.edit, color: (!isOwner || isCurrentUser) ? null : AppTheme.textTertiary),
                        title: Text(
                          'Change Role',
                          style: TextStyle(
                            color: (!isOwner || isCurrentUser) ? null : AppTheme.textTertiary,
                          ),
                        ),
                        subtitle: isOwner && !isCurrentUser
                            ? const Text(
                                'Owner role cannot be changed',
                                style: TextStyle(fontSize: 11, color: AppTheme.textTertiary),
                              )
                            : null,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    PopupMenuItem(
                      value: 'remove',
                      enabled: !isOwner && !isCurrentUser, // Can't remove owner or yourself
                      child: ListTile(
                        leading: Icon(
                          Icons.remove_circle,
                          color: (!isOwner && !isCurrentUser) ? AppTheme.error : AppTheme.textTertiary,
                        ),
                        title: Text(
                          'Remove Access',
                          style: TextStyle(
                            color: (!isOwner && !isCurrentUser) ? AppTheme.error : AppTheme.textTertiary,
                          ),
                        ),
                        subtitle: isOwner
                            ? const Text(
                                'Owner cannot be removed',
                                style: TextStyle(fontSize: 11, color: AppTheme.textTertiary),
                              )
                            : isCurrentUser
                                ? const Text(
                                    'You cannot remove yourself',
                                    style: TextStyle(fontSize: 11, color: AppTheme.textTertiary),
                                  )
                                : null,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ];
                },
              ),
            ),
          ),
        );
      }
    }

    if (pendingInvites.isNotEmpty) {
      children.add(const SizedBox(height: 16));
      children.add(_buildPendingInvitesSection(pendingInvites));
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: children,
    );
  }

  Widget _buildRolesTab() {
    final roles = PermissionService.getPredefinedRoles();
    
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: roles.length,
      itemBuilder: (context, index) {
        final role = roles[index];
        
        return Card(
          margin: const EdgeInsets.only(bottom: 16),
          child: ExpansionTile(
            leading: CircleAvatar(
              backgroundColor: role.color.withOpacity(0.1),
              child: Icon(_getRoleIcon(role.type), color: role.color),
            ),
            title: Text(
              role.name,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(role.description),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Permissions (${role.permissions.length}):',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: role.permissions.map((permission) {
                        return Chip(
                          label: Text(permission.displayName),
                          backgroundColor: role.color.withOpacity(0.1),
                          labelStyle: TextStyle(color: role.color),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSettingsTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Permission Settings',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: Icon(Icons.add_circle, color: AppTheme.success),
              title: const Text('Add User to Facility'),
              subtitle: const Text('Grant access to a user for this facility'),
              trailing: const Icon(Icons.arrow_forward_ios),
              onTap: _showAddUserDialog,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: Icon(Icons.assignment, color: AppTheme.primaryBlue),
              title: const Text('Audit Logs'),
              subtitle: const Text('View permission changes and access logs'),
              trailing: const Icon(Icons.arrow_forward_ios),
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Audit logs feature coming soon')),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: Icon(Icons.security, color: AppTheme.warning),
              title: const Text('Security Settings'),
              subtitle: const Text('Configure security policies and restrictions'),
              trailing: const Icon(Icons.arrow_forward_ios),
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Security settings feature coming soon')),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  IconData _getRoleIcon(RoleType roleType) {
    switch (roleType) {
      case RoleType.owner:
        return Icons.star;
      case RoleType.manager:
        return Icons.manage_accounts;
      case RoleType.employee:
        return Icons.person;
      case RoleType.viewer:
        return Icons.visibility;
      case RoleType.admin:
        return Icons.admin_panel_settings;
    }
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }

  Widget _buildPendingInvitesSection(List<FacilityInvite> invites) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.mail_outline, color: AppTheme.primaryBlue),
                const SizedBox(width: 8),
                Text(
                  'Pending Invitations (${invites.length})',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Column(
              children: invites.map((invite) {
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(vertical: 4),
                  leading: const Icon(Icons.pending_actions),
                  title: Text(invite.email),
                  subtitle: Text(
                    '${invite.roleType.displayName} • Invited ${_formatDate(invite.invitedAt)}',
                  ),
                  trailing: Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: () => _resendInvite(invite),
                        child: const Text('Resend'),
                      ),
                      TextButton(
                        onPressed: () => _cancelInvite(invite),
                        child: const Text(
                          'Cancel',
                          style: TextStyle(color: AppTheme.error),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _cancelInvite(FacilityInvite invite) async {
    if (_selectedFacilityId == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Invitation'),
        content: Text(
          'Cancel the invitation sent to ${invite.email}? They will no longer be able to join automatically.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep Invite'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel Invite'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      if (kDebugMode) {
        print('🔄 [PermissionManagement] Cancelling invite: ${invite.email}, inviteId=${invite.id}');
      }
      
      await PermissionService.cancelFacilityInvite(
        facilityId: _selectedFacilityId!,
        inviteId: invite.id,
      );
      
      if (!mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Invitation to ${invite.email} cancelled.'),
          backgroundColor: AppTheme.success,
        ),
      );
      
      // Reload users/invites list to reflect changes
      // Note: Email may have already been sent before cancellation - this is expected behavior
      await _loadFacilityUsers();
      
      if (kDebugMode) {
        print('✅ [PermissionManagement] Invite cancelled successfully');
      }
    } catch (e) {
      if (!mounted) return;
      
      if (kDebugMode) {
        print('❌ [PermissionManagement] Error cancelling invite: $e');
      }
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error cancelling invite: $e'),
          backgroundColor: AppTheme.error,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _resendInvite(FacilityInvite invite) async {
    if (_selectedFacilityId == null) return;
    try {
      final success = await PermissionService.resendFacilityInvite(
        facilityId: _selectedFacilityId!,
        inviteId: invite.id,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'Invitation re-sent to ${invite.email}. They will receive an email with instructions to join.'
                : 'Unable to resend invitation. Please try again later.',
          ),
          backgroundColor: success ? AppTheme.success : AppTheme.warning,
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error resending invite: $e'),
          backgroundColor: AppTheme.error,
        ),
      );
    }
  }

  void _handleUserAction(String action, UserRole userRole) {
    switch (action) {
      case 'change_role':
        _showChangeRoleDialog(userRole);
        break;
      case 'remove':
        _showRemoveUserDialog(userRole);
        break;
    }
  }

  void _showAddUserDialog() {
    // Capture the page context so we can safely show snackbars after closing dialogs.
    final pageContext = context;

    if (_selectedFacilityId == null) {
      ScaffoldMessenger.of(pageContext).showSnackBar(
        const SnackBar(content: Text('Select a facility before adding users.')),
      );
      return;
    }

    final emailController = TextEditingController();
    RoleType selectedRole = RoleType.viewer;
    String? errorMessage;
    bool isSubmitting = false;

    final roles = PermissionService.getPredefinedRoles()
        .where((role) => role.type != RoleType.owner) // Prevent granting owner via UI
        .toList();

    showDialog(
      context: pageContext,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogInnerContext, setState) {
          Future<void> handleAddUser() async {
            final email = emailController.text.trim();
            final emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

            if (email.isEmpty) {
              setState(() => errorMessage = 'Please enter an email address.');
              return;
            }

            if (!emailRegex.hasMatch(email)) {
              setState(() => errorMessage = 'Enter a valid email address.');
              return;
            }

            setState(() {
              errorMessage = null;
              isSubmitting = true;
            });

            try {
              // Always create a pending invite, regardless of whether user exists
              // This ensures users have the choice to accept or decline, even if they already have an account
              setState(() => isSubmitting = false);

              final shouldInvite = await showDialog<bool>(
                context: pageContext,
                builder: (confirmContext) => AlertDialog(
                  title: const Text('Send Invitation?'),
                  content: Text(
                    'Send an invitation email to $email to join this facility as a ${selectedRole.displayName}?',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(confirmContext).pop(false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(confirmContext).pop(true),
                      child: const Text('Send Invite'),
                    ),
                  ],
                ),
              );

              if (shouldInvite != true) {
                setState(() {
                  errorMessage = 'Invitation not sent.';
                  isSubmitting = false;
                });
                return;
              }

              setState(() => isSubmitting = true);
              
              try {
                final currentUser = FirebaseAuth.instance.currentUser;
                final result = await PermissionService.createFacilityInvite(
                  facilityId: _selectedFacilityId!,
                  email: email,
                  roleType: selectedRole,
                  invitedBy: currentUser?.uid ?? 'system',
                  invitedByEmail: currentUser?.email,
                );

                if (!mounted) return;
                
                setState(() => isSubmitting = false);
                Navigator.of(dialogContext).pop();
                
                if (result.success) {
                  ScaffoldMessenger.of(pageContext).showSnackBar(
                    SnackBar(
                      content: Text('Invitation sent to $email. They will receive an email with instructions to join.'),
                      backgroundColor: AppTheme.success,
                      duration: const Duration(seconds: 4),
                    ),
                  );
                } else {
                  final errorMsg = result.errorMessage ?? 'Unknown error';
                  print('❌ [PermissionManagementScreen] Invite creation failed: $errorMsg');
                  ScaffoldMessenger.of(pageContext).showSnackBar(
                    SnackBar(
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Invite created but email failed to send.', style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text('Error: $errorMsg', style: const TextStyle(fontSize: 12)),
                          const SizedBox(height: 4),
                          const Text('You can resend it from the pending invites section.', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                      backgroundColor: AppTheme.warning,
                      duration: const Duration(seconds: 10),
                    ),
                  );
                }
                // Try to reload users, but don't fail if it errors
                try {
                  await _loadFacilityUsers();
                } catch (reloadError) {
                  print('⚠️ [PermissionManagementScreen] Error reloading users after invite: $reloadError');
                  // Don't show error - invite was created successfully
                }
              } catch (e) {
                if (!mounted) return;
                print('❌ [PermissionManagementScreen] Error in invite flow: $e');
                setState(() {
                  errorMessage = 'Error sending invitation: $e';
                  isSubmitting = false;
                });
              }
            } catch (e) {
              setState(() {
                errorMessage = 'Error adding user: $e';
                isSubmitting = false;
              });
            }
          }

          return AlertDialog(
            title: const Text('Add User to Facility'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'User Email',
                    hintText: 'user@example.com',
                  ),
                  enabled: !isSubmitting,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<RoleType>(
                  value: selectedRole,
                  items: roles.map((role) {
                    return DropdownMenuItem<RoleType>(
                      value: role.type,
                      child: Text(role.name),
                    );
                  }).toList(),
                  onChanged: isSubmitting
                      ? null
                      : (value) {
                          if (value != null) {
                            setState(() => selectedRole = value);
                          }
                        },
                  decoration: const InputDecoration(
                    labelText: 'Role',
                  ),
                ),
                if (errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    errorMessage!,
                    style: TextStyle(color: AppTheme.error),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: isSubmitting ? null : () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              ElevatedButton.icon(
                onPressed: isSubmitting ? null : handleAddUser,
                icon: isSubmitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.person_add),
                label: const Text('Add User'),
              ),
            ],
          );
        },
      ),
    ).whenComplete(() => emailController.dispose());
  }

  void _showChangeRoleDialog(UserRole userRole) {
    final currentUser = FirebaseAuth.instance.currentUser;
    final facility = _selectedFacilityId != null
        ? _facilities.firstWhere(
            (f) => f.id == _selectedFacilityId,
            orElse: () => _facilities.first,
          )
        : null;
    
    final isOwner = facility != null && facility.ownerUid == userRole.userId;
    final isCurrentUser = currentUser?.uid == userRole.userId;
    
    // Prevent changing owner role unless it's the current user changing their own role
    if (isOwner && !isCurrentUser) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Owner role cannot be changed. Only the facility owner can modify their own role.'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }
    
    final roles = PermissionService.getPredefinedRoles();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isCurrentUser ? 'Change Your Role' : 'Change User Role'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: roles.map((role) {
              final isCurrentRole = role.type == userRole.roleType;
              final isOwnerRole = role.type == RoleType.owner;
              
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: role.color.withOpacity(0.1),
                  child: Icon(_getRoleIcon(role.type), color: role.color),
                ),
                title: Row(
                  children: [
                    Expanded(child: Text(role.name)),
                    if (isCurrentRole)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryBlue.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          'Current',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                        ),
                      ),
                  ],
                ),
                subtitle: Text(role.description),
                enabled: !isOwnerRole || isCurrentUser, // Only allow owner role if it's current user
                onTap: isOwnerRole && !isCurrentUser
                    ? null
                    : () {
                        Navigator.of(context).pop();
                        _changeUserRole(userRole, role.type);
                      },
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  void _showRemoveUserDialog(UserRole userRole) {
    final currentUser = FirebaseAuth.instance.currentUser;
    final facility = _selectedFacilityId != null
        ? _facilities.firstWhere(
            (f) => f.id == _selectedFacilityId,
            orElse: () => _facilities.first,
          )
        : null;
    
    final isOwner = facility != null && facility.ownerUid == userRole.userId;
    final isCurrentUser = currentUser?.uid == userRole.userId;
    
    // Prevent removing owner or current user
    if (isOwner) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot remove facility owner. The owner role is permanent.'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }
    
    if (isCurrentUser) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You cannot remove your own access. Ask another administrator to do this.'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }
    
    final userEmail = _userProfiles[userRole.userId]?['email'] ?? userRole.userId;
    final userName = _userProfiles[userRole.userId]?['displayName'] ?? userEmail;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove User Access'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Are you sure you want to remove access for:'),
            const SizedBox(height: 8),
            Text(
              userName,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            Text(
              userEmail,
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.warning.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.warning.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning, color: AppTheme.warning, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This user will lose all access to this facility and cannot be undone.',
                      style: TextStyle(fontSize: 12, color: AppTheme.warning),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _removeUser(userRole);
            },
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: const Text('Remove Access'),
          ),
        ],
      ),
    );
  }

  Future<void> _changeUserRole(UserRole userRole, RoleType newRoleType) async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final result = await PermissionService.assignRole(
        userId: userRole.userId,
        facilityId: userRole.facilityId,
        roleType: newRoleType,
        assignedBy: FirebaseAuth.instance.currentUser?.uid ?? 'system',
      );
      
      if (mounted) {
        if (result.success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Role changed successfully')),
          );
          await _loadFacilityUsers();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to change role')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error changing role: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _removeUser(UserRole userRole) async {
    // Safety check: prevent removing owner or current user
    final facility = _selectedFacilityId != null
        ? _facilities.firstWhere(
            (f) => f.id == _selectedFacilityId,
            orElse: () => _facilities.first,
          )
        : null;
    
    final isOwner = facility != null && facility.ownerUid == userRole.userId;
    final currentUser = FirebaseAuth.instance.currentUser;
    final isCurrentUser = currentUser?.uid == userRole.userId;
    
    if (isOwner) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot remove facility owner. The owner role is permanent.'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
      return;
    }
    
    if (isCurrentUser) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('You cannot remove your own access. Ask another administrator to do this.'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
      return;
    }
    
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final success = await PermissionService.removeRole(
        userId: userRole.userId,
        facilityId: userRole.facilityId,
      );
      
      if (mounted) {
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('User access removed'),
              backgroundColor: AppTheme.success,
            ),
          );
          await _loadFacilityUsers();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to remove user access'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error removing user: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }
}
