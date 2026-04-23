import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/app_theme.dart';

/// Super-admin walkthrough: custom hostname + SFC-hosted public website.
/// Content is bundled from [docs/SUPERADMIN_CUSTOM_DOMAIN_WEBSITE.md].
class CustomDomainGuideTab extends StatefulWidget {
  const CustomDomainGuideTab({super.key});

  @override
  State<CustomDomainGuideTab> createState() => _CustomDomainGuideTabState();
}

class _CustomDomainGuideTabState extends State<CustomDomainGuideTab> {
  late final Future<String> _markdownFuture;

  @override
  void initState() {
    super.initState();
    _markdownFuture = rootBundle
        .loadString('docs/SUPERADMIN_CUSTOM_DOMAIN_WEBSITE.md')
        .catchError((Object e) => 'Failed to load guide: $e');
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _markdownFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final text = snap.data ?? 'No content.';
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'Custom domain + public website',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Checklist and DNS/Firebase steps when a facility wants our website on their domain. '
              'Also in repo: docs/SUPERADMIN_CUSTOM_DOMAIN_WEBSITE.md',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            SelectableText(
              text,
              style: const TextStyle(
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
        );
      },
    );
  }
}
