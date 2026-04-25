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
      '''Subject: DNS needed for your Storage Facility Creator website

Hi,

We're connecting your domain to your Storage Facility Creator public website. Please add the DNS records Firebase shows (we'll paste them below after adding your hostname in our Firebase project).

[PASTE TXT + CNAME/A RECORDS FROM FIREBASE HOSTING — CUSTOM DOMAINS SCREEN HERE]

If someone else manages your domain (GoDaddy, Cloudflare, etc.), forward this email to them. Nothing else is required on your side until DNS is saved.

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
      setState(() => _error = 'Hostname is required.');
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
                    'Custom domain (public website)',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Use this when a facility wants their own address (e.g. rent.theirstorage.com) '
                    'to show the same SFC-hosted marketing site as $kAppWebHostname/w/…',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppTheme.textSecondary,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _GuideCard(
                    icon: Icons.cloud_sync_outlined,
                    title: 'Provision on Firebase Hosting (API)',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Creates/links the hostname on Firebase Hosting, then shows DNS records and SSL status.',
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _hostnameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Hostname',
                            hintText: 'rent.theirstorage.com',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _facilityIdCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Facility ID (optional if slug set)',
                            hintText: 'abc123FacilityId',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _slugCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Public slug (optional)',
                            hintText: 'my-storage',
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
                              label: const Text('Provision'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _busy ? null : _refreshStatus,
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text('Refresh status'),
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
                    icon: Icons.link,
                    title: 'Option A — easiest (no DNS)',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'They use our link. It works as soon as the facility publishes Website Setup.',
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
                          label: const Text('Copy example'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _GuideCard(
                    icon: Icons.dns_outlined,
                    title: 'Option B — their domain (3 steps)',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _NumberStep(
                          n: 1,
                          title: 'In SFC (facility account)',
                          body:
                              'Settings → Website Setup. Set **Website URL name** (the `/w/…` slug). '
                              'Put the **exact** hostname they want (e.g. `rent.theirstorage.com`) in **Custom domain**. Save.',
                        ),
                        const SizedBox(height: 14),
                        _NumberStep(
                          n: 2,
                          title: 'Provision in SFC (Super Admin)',
                          body:
                              'Use **Provision on Firebase Hosting (API)** above with the same hostname. '
                              'It returns TXT + A/CNAME records and status in-app.',
                        ),
                        const SizedBox(height: 14),
                        _NumberStep(
                          n: 3,
                          title: 'Customer DNS (their registrar)',
                          body:
                              'They add those records at GoDaddy, Cloudflare, Namecheap, etc. '
                              'When DNS propagates, Firebase finishes SSL. Then '
                              '`https://their-host/` redirects to the published marketing page.',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _GuideCard(
                    icon: Icons.mail_outline,
                    title: 'Email draft for the customer',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Copy, paste records from Firebase into the bracket, then send.',
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
                    title: 'Quick fixes',
                    child: Column(
                      children: [
                        _Bullet(
                          "**Site can't be reached / NXDOMAIN** — they never created DNS, "
                          'or typo in hostname. Use Option A link until DNS is fixed.',
                        ),
                        _Bullet(
                          '**Certificate stuck / SSL pending** — records do not match Firebase, '
                          'or wait up to a few hours. Turn off orange-cloud proxy while provisioning if unsure.',
                        ),
                        _Bullet(
                          '**Wrong facility or blank site** — Custom domain in Website Setup must '
                          'match the hostname exactly; republish Website Setup.',
                        ),
                        _Bullet(
                          '**Root shows operator app** — verify Hosting deploy includes `routeCustomDomainRoot` rewrite and function.',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Engineering reference: docs/SUPERADMIN_CUSTOM_DOMAIN_WEBSITE.md in the repo.',
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
            'Status: ${result.status} (${result.certState ?? 'unknown cert'})',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            'Facility: ${result.facilityId}    Slug: ${result.slug}\nHostname: ${result.hostname}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          if (result.records.isEmpty)
            const Text('No DNS records returned yet. Use Refresh status.')
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
