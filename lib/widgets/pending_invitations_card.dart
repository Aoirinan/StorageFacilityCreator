import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/services/error_reporter.dart';
import 'package:sfcapp/services/permission_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// The invitations waiting for the signed-in user, each with its link.
///
/// Only a genuinely new invitee's recent invites are accepted without the
/// link. Anyone else (and a new invitee whose only invite was sent more than
/// [PermissionService.inviteAutoAcceptWindow] ago) was left with no role, no
/// account and nothing on the dashboard to say why: the link was only in the
/// email.
class PendingInvitationsCard extends StatefulWidget {
  const PendingInvitationsCard({super.key, required this.user, this.loadInvites});

  final User user;

  /// [PermissionService.pendingInvitesFor] unless a test passes its own.
  final Future<List<FacilityInvite>> Function(User user)? loadInvites;

  /// Where "Open invitation" goes for [invite]: the page its email links to.
  static String linkFor(FacilityInvite invite) => Uri(
        path: AppRoute.acceptInvite,
        queryParameters: {'facilityId': invite.facilityId, 'inviteId': invite.id},
      ).toString();

  @override
  State<PendingInvitationsCard> createState() => _PendingInvitationsCardState();
}

class _PendingInvitationsCardState extends State<PendingInvitationsCard> {
  List<FacilityInvite> _invites = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PendingInvitationsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Another login on the same dashboard: its invitations, not the last one's.
    if (oldWidget.user.uid != widget.user.uid) {
      _invites = const [];
      _load();
    }
  }

  Future<void> _load() async {
    final uid = widget.user.uid;
    try {
      final invites =
          await (widget.loadInvites ?? PermissionService.pendingInvitesFor)(widget.user);
      if (mounted && widget.user.uid == uid) setState(() => _invites = invites);
    } catch (e, st) {
      // Nothing to show is the dashboard as it was; the email still works.
      ErrorReporter.reportError(e, st, context: 'PendingInvitationsCard');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_invites.isEmpty) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: AppTheme.primaryBlue.withValues(alpha: 0.4)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.mail_outline, color: AppTheme.primaryBlue),
                  const SizedBox(width: 8),
                  Text(
                    _invites.length == 1
                        ? 'You have an invitation'
                        : 'You have ${_invites.length} invitations',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
              for (final invite in _invites) _InvitationRow(invite: invite),
            ],
          ),
        ),
      ),
    );
  }
}

class _InvitationRow extends StatelessWidget {
  const _InvitationRow({required this.invite});

  final FacilityInvite invite;

  @override
  Widget build(BuildContext context) {
    final facility = (invite.facilityName ?? '').trim();
    final role = PermissionService.getRoleByType(invite.roleType)?.name ?? invite.roleType.name;
    final detail = invite.autoAcceptable
        ? (invite.invitedByEmail == null ? null : 'Invited by ${invite.invitedByEmail}')
        : 'Sent more than ${PermissionService.inviteAutoAcceptWindow.inDays} days ago, so '
            'it was not accepted automatically. Open it to join; if it no longer '
            'works, ask the owner to send a new one.';
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Join ${facility.isEmpty ? 'a facility' : facility} as $role',
                  // The name is whatever the sender called their facility,
                  // on any invited user's dashboard: kept to a title's length.
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                if (detail != null)
                  Text(
                    detail,
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                  ),
              ],
            ),
          ),
          FilledButton(
            onPressed: () => context.go(PendingInvitationsCard.linkFor(invite)),
            child: const Text('Open invitation'),
          ),
        ],
      ),
    );
  }
}
