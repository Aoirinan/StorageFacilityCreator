import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/app_theme.dart';
import '../router/app_route.dart';

/// Contact page for support and inquiries.
class ContactScreen extends StatelessWidget {
  const ContactScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contact Us'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go(AppRoute.landing),
        ),
      ),
      body: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Contact Us',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'We\'re here to help',
                  style: TextStyle(
                    fontSize: 18,
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 32),
                const Divider(),
                const SizedBox(height: 32),
                _ContactSection(
                  icon: Icons.email_outlined,
                  title: 'Email Support',
                  content: 'For general inquiries, support questions, or partnership opportunities, please email us at support@storagefacilitycreator.com',
                  actionLabel: 'Send Email',
                  onAction: () {
                    // Could open email client or show email address
                  },
                ),
                _ContactSection(
                  icon: Icons.business_outlined,
                  title: 'Business Hours',
                  content: 'Our support team is available Monday through Friday, 9:00 AM to 5:00 PM Eastern Time. We typically respond to inquiries within 24-48 hours during business days.',
                ),
                _ContactSection(
                  icon: Icons.info_outline,
                  title: 'Support Expectations',
                  content: '''We aim to respond to all inquiries within 24-48 hours during business days. For urgent matters related to your account or facility operations, please contact your facility administrator directly.

For technical support, account questions, or billing inquiries, our support team is ready to assist you.''',
                ),
                _ContactSection(
                  icon: Icons.location_on_outlined,
                  title: 'Physical Address',
                  content: 'Storage Facility Creator is a cloud-based SaaS platform. We do not maintain a physical office location. All support is provided remotely via email and our web platform.',
                ),
                const SizedBox(height: 32),
                const Divider(),
                const SizedBox(height: 24),
                const Text(
                  'Other Resources',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    _ResourceLink(
                      label: 'Privacy Policy',
                      onTap: () => context.go('/privacy'),
                    ),
                    _ResourceLink(
                      label: 'Terms of Service',
                      onTap: () => context.go('/terms'),
                    ),
                    _ResourceLink(
                      label: 'SMS Policy',
                      onTap: () => context.go('/sms-policy'),
                    ),
                    _ResourceLink(
                      label: 'FAQ',
                      onTap: () => context.go(AppRoute.landing),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                ElevatedButton(
                  onPressed: () => context.go(AppRoute.landing),
                  child: const Text('Back to Home'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ContactSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final String content;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _ContactSection({
    required this.icon,
    required this.title,
    required this.content,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 32),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.primaryBlue.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: AppTheme.primaryBlue, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  content,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.6,
                    color: AppTheme.textSecondary,
                  ),
                ),
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: onAction,
                    child: Text(actionLabel!),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ResourceLink extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _ResourceLink({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderLight),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: AppTheme.primaryBlue,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
