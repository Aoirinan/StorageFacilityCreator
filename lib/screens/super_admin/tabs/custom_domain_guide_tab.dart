import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:sfcapp/config/web_host_config.dart';
import 'package:sfcapp/services/super_admin_data_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// Short super-admin guide: facility public website on **their** hostname.
class CustomDomainGuideTab extends StatefulWidget {
  const CustomDomainGuideTab({super.key});

  @override
  State<CustomDomainGuideTab> createState() => _CustomDomainGuideTabState();
}

class _CustomDomainGuideTabState extends State<CustomDomainGuideTab> {
  final _hostnameCtrl = TextEditingController();
  final _facilityIdCtrl = TextEditingController();
  final _slugCtrl = TextEditingController();
  bool _busy = false;
  String? _error;
  HostingCustomDomainProvisionResult? _result;

  @override
  void dispose() {
    _hostnameCtrl.dispose();
    _facilityIdCtrl.dispose();
    _slugCtrl.dispose();
    super.dispose();
  }

  static const _emailDraft =
      '''Subject: One step needed for your website address

Hi,

We are setting up your custom website address (for example, rent.yourstorage.com) so it shows your Storage Facility Creator marketing site.

Your domain provider (GoDaddy, Cloudflare, Namecheap, etc.) needs a few DNS records added. Please copy the records below into your domain settings, or forward this email to whoever manages your domain for you.

[PASTE THE DNS RECORDS FROM THE SETUP TOOL ABOVE HERE]

After you save the records, it can take a few minutes to a few hours for the site to go live. You do not need to do anything else on our end.

Thanks,
Storage Facility Creator support''';

  void _copy(BuildContext context, String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.success,
      ),
    );
  }

  Future<void> _provision() async {
    final hostname = _hostnameCtrl.text.trim();
    if (hostname.isEmpty) {
      setState(() => _error = 'Enter the website address you want to connect.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await SuperAdminDataService.provisionHostingCustomDomain(
        hostname: hostname,
        facilityId: _facilityIdCtrl.text.trim().isEmpty
            ? null
            : _facilityIdCtrl.text.trim(),
        slug: _slugCtrl.text.trim().isEmpty ? null : _slugCtrl.text.trim(),
      );
      setState(() => _result = res);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshStatus() async {
    final hostname = (_result?.hostname ?? _hostnameCtrl.text).trim();
    if (hostname.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await SuperAdminDataService.getHostingCustomDomainStatus(
        hostname: hostname,
      );
      setState(() => _result = res);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final publicExample = 'https://$kAppWebHostname/w/your-slug-here';

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth > 760 ? 720.0 : constraints.maxWidth;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxW),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Custom website address',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Help a facility share their marketing website. They can use our standard link right away, '
                    'or use their own address (like rent.theirstorage.com) after a short DNS setup.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppTheme.textSecondary,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 20),
                  _GuideCard(
                    icon: Icons.link,
                    title: 'Option 1 — Use our link (no setup)',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Share this link with the facility. It works as soon as they publish Website Setup — '
                          'no domain or DNS work needed.',
                        ),
                        const SizedBox(height: 12),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppTheme.borderLight),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: SelectableText(
                              publicExample,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: () =>
                              _copy(context, 'Example link', publicExample),
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Copy example link'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _GuideCard(
                    icon: Icons.dns_outlined,
                    title: 'Option 2 — Use their own website address',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Use this when they want visitors to type their own domain instead of our link. '
                          'It takes three steps and usually involves their domain provider (GoDaddy, Cloudflare, etc.).',
                        ),
                        const SizedBox(height: 16),
                        _NumberStep(
                          n: 1,
                          title: 'Facility sets up Website Setup',
                          body:
                              'In their account: **Settings → Website Setup**. Set **Website URL name** (the `/w/…` part). '
                              'Enter the **exact** address they want (e.g. `rent.theirstorage.com`) in **Custom domain**, then save.',
                        ),
                        const SizedBox(height: 14),
                        _NumberStep(
                          n: 2,
                          title: 'You connect the domain here',
                          body:
                              'Use **Connect a custom domain** below with the same website address. '
                              'You will get DNS records to send to the customer.',
                        ),
                        const SizedBox(height: 14),
                        _NumberStep(
                          n: 3,
                          title: 'Customer adds DNS records',
                          body:
                              'They (or their IT person) add those records at their domain provider. '
                              'After DNS updates, the site usually goes live within a few minutes to a few hours.',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _GuideCard(
                    icon: Icons.cloud_sync_outlined,
                    title: 'Connect a custom domain',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Step 2 of Option 2. Enter the facility\'s website address to register it and get the DNS records they need.',
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _hostnameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Website address',
                            hintText: 'rent.theirstorage.com',
                            helperText:
                                'The domain only — no https:// or paths',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _facilityIdCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Facility ID (optional)',
                            hintText: 'abc123FacilityId',
                            helperText:
                                'Only if needed — find it on the Facilities tab',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _slugCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Website URL name (optional)',
                            hintText: 'my-storage',
                            helperText:
                                'The /w/... name from Website Setup — can be used instead of Facility ID',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            FilledButton.icon(
                              onPressed: _busy ? null : _provision,
                              icon: _busy
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.rocket_launch, size: 18),
                              label: const Text('Connect domain'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _busy ? null : _refreshStatus,
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text('Check progress'),
                            ),
                          ],
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            _error!,
                            style: const TextStyle(color: AppTheme.error),
                          ),
                        ],
                        if (_result != null) ...[
                          const SizedBox(height: 14),
                          _ProvisionResultCard(
                            result: _result!,
                            onCopyRecord: (record) => _copy(
                              context,
                              'DNS record',
                              '${record.type} ${record.name} ${record.value}',
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _GuideCard(
                    icon: Icons.mail_outline,
                    title: 'Email to send the customer',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'After connecting the domain, copy this draft, paste the DNS records into the bracket, and send it to the facility or their domain manager.',
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: () =>
                              _copy(context, 'Email draft', _emailDraft),
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Copy email draft'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _GuideCard(
                    icon: Icons.troubleshoot,
                    title: 'Common problems',
                    child: Column(
                      children: [
                        _Bullet(
                          "**Site can't be reached** — DNS records were never added, or the website address has a typo. "
                          'Share the Option 1 link until DNS is fixed.',
                        ),
                        _Bullet(
                          '**Security certificate still pending** — DNS records may not match yet, or propagation is still in progress. '
                          'Wait a few hours and tap **Check progress**. If using Cloudflare, turn off the orange-cloud proxy while setting up.',
                        ),
                        _Bullet(
                          '**Wrong facility or blank page** — the **Custom domain** in Website Setup must match exactly. '
                          'Have the facility save Website Setup again.',
                        ),
                        _Bullet(
                          '**Root domain shows the operator app** — engineering issue: verify Hosting deploy includes the custom-domain redirect.',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Technical reference: docs/SUPERADMIN_CUSTOM_DOMAIN_WEBSITE.md',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _GuideCard extends StatelessWidget {
  const _GuideCard({
    required this.icon,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppTheme.borderLight),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 22, color: AppTheme.primaryBlue),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DefaultTextStyle.merge(
              style: theme.textTheme.bodyMedium!.copyWith(height: 1.45),
              child: child,
            ),
          ],
        ),
      ),
    );
  }
}

class _NumberStep extends StatelessWidget {
  const _NumberStep({
    required this.n,
    required this.title,
    required this.body,
  });

  final int n;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 14,
          backgroundColor: AppTheme.primaryBlue.withValues(alpha: 0.12),
          child: Text(
            '$n',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: AppTheme.primaryBlue,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text.rich(
                TextSpan(
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppTheme.textPrimary,
                        height: 1.45,
                      ),
                  children: _boldSegments(body),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Turns `**like this**` into bold spans (simple parser).
  static List<InlineSpan> _boldSegments(String raw) {
    final spans = <InlineSpan>[];
    final re = RegExp(r'\*\*(.+?)\*\*');
    var start = 0;
    for (final m in re.allMatches(raw)) {
      if (m.start > start) {
        spans.add(TextSpan(text: raw.substring(start, m.start)));
      }
      spans.add(TextSpan(
        text: m.group(1),
        style: const TextStyle(fontWeight: FontWeight.w700),
      ));
      start = m.end;
    }
    if (start < raw.length) {
      spans.add(TextSpan(text: raw.substring(start)));
    }
    return spans.isEmpty ? [TextSpan(text: raw)] : spans;
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('•  ', style: TextStyle(fontWeight: FontWeight.w900)),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      height: 1.45,
                    ),
                children: _NumberStep._boldSegments(text),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProvisionResultCard extends StatelessWidget {
  const _ProvisionResultCard({
    required this.result,
    required this.onCopyRecord,
  });

  final HostingCustomDomainProvisionResult result;
  final ValueChanged<HostingDnsRecord> onCopyRecord;

  static String _friendlyStatus(String status) {
    switch (status.toLowerCase()) {
      case 'connected':
        return 'Live — website address is working';
      case 'provisioning_ssl':
        return 'Almost ready — finishing the security certificate';
      case 'pending_dns':
        return 'Waiting — customer still needs to add DNS records';
      default:
        return status.replaceAll('_', ' ');
    }
  }

  static String? _friendlyCertHint(String? certState) {
    if (certState == null || certState.isEmpty) return null;
    switch (certState.toLowerCase()) {
      case 'active':
        return 'Security certificate is active';
      case 'provisioning':
        return 'Security certificate is being issued — can take up to a few hours';
      default:
        return 'Certificate: ${certState.replaceAll('_', ' ')}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final certHint = _friendlyCertHint(result.certState);
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderLight),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _friendlyStatus(result.status),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (certHint != null) ...[
            const SizedBox(height: 4),
            Text(
              certHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppTheme.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 8),
          SelectableText(
            'Website address: ${result.hostname}\n'
            'Facility: ${result.facilityId.isEmpty ? '—' : result.facilityId}    '
            'URL name: ${result.slug.isEmpty ? '—' : result.slug}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Text(
            'DNS records for the customer\'s domain provider',
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Copy each row and add it in GoDaddy, Cloudflare, Namecheap, or wherever they manage their domain.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppTheme.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          if (result.records.isEmpty)
            const Text(
              'No DNS records yet. Tap Check progress in a minute or two.',
            )
          else
            ...result.records.map(
              (record) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: SelectableText(
                        '${record.type}    ${record.name}    ${record.value}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy record',
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () => onCopyRecord(record),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
