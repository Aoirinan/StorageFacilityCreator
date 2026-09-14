/// Result of `sendTenantPortalInvites`, and how to say it in one line.
class PortalInviteSummary {
  final int requested;
  final int sent;
  final int blockedPrelaunch;
  final int skippedNoEmail;
  final int unsubscribed;
  final int failed;
  final int codesGenerated;

  const PortalInviteSummary({
    required this.requested,
    required this.sent,
    required this.blockedPrelaunch,
    required this.skippedNoEmail,
    required this.unsubscribed,
    required this.failed,
    required this.codesGenerated,
  });

  factory PortalInviteSummary.fromMap(Map<String, dynamic> m) {
    int n(String k) => (m[k] as num?)?.toInt() ?? 0;
    return PortalInviteSummary(
      requested: n('requested'),
      sent: n('sent'),
      blockedPrelaunch: n('blockedPrelaunch'),
      skippedNoEmail: n('skippedNoEmail'),
      unsubscribed: n('unsubscribed'),
      failed: n('failed'),
      codesGenerated: n('codesGenerated'),
    );
  }

  /// One sentence for a snackbar. Leads with what the operator cares about
  /// and names the pre-launch gate so a "sent 0" is not read as a failure.
  String describe() {
    final parts = <String>[];
    parts.add('Sent $sent of $requested');
    if (blockedPrelaunch > 0) parts.add('$blockedPrelaunch held by the pre-launch gate');
    if (skippedNoEmail > 0) parts.add('$skippedNoEmail with no email on file');
    if (unsubscribed > 0) parts.add('$unsubscribed unsubscribed');
    if (failed > 0) parts.add('$failed failed');
    if (codesGenerated > 0) parts.add('$codesGenerated new access ${codesGenerated == 1 ? 'code' : 'codes'} created');
    return '${parts.join('. ')}.';
  }

  bool get anythingWentWrong => failed > 0;
}
