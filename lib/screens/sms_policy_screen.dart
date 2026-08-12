import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/app_theme.dart';
import '../router/app_route.dart';

/// SMS Messaging Policy page for Twilio A2P compliance.
class SMSPolicyScreen extends StatelessWidget {
  const SMSPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: cs.surface,
        foregroundColor: cs.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 1,
        title: Text(
          'SMS Messaging Policy',
          style: theme.textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go(AppRoute.landing),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: cs.outlineVariant),
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
                  'SMS Messaging Policy',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Last updated: January 28, 2026',
                  style: TextStyle(
                    fontSize: 14,
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 32),
                const Divider(),
                const SizedBox(height: 32),
                _PolicySection(
                  title: 'Consent and Opt-In',
                  content: '''By providing your mobile phone number and checking the consent box during account creation, you agree to receive SMS messages from Storage Facility Creator and the facility you are associated with.

These messages may include:
• Payment reminders and billing notifications
• Account updates and important notices
• Access code information
• Move-in and move-out confirmations
• Other account-related communications

You can opt in by checking the consent box that states: "I agree to receive SMS reminders and account notifications from [Facility Name]. Reply STOP to opt out, HELP for help. Message frequency varies. Msg & data rates may apply."''',
                ),
                _PolicySection(
                  title: 'Message Frequency',
                  content: '''Message frequency varies based on your account activity and the communications sent by your facility. You may receive messages:
• When payments are due or overdue
• When account information changes
• When access codes are updated
• For important account notifications
• In response to your inquiries

The frequency of messages depends on your facility's communication preferences and your account activity.''',
                ),
                _PolicySection(
                  title: 'Message and Data Rates',
                  content: '''Message and data rates may apply. Standard message and data rates charged by your mobile carrier will apply to SMS messages sent and received. Storage Facility Creator and your facility are not responsible for any charges incurred from your mobile carrier.''',
                ),
                _PolicySection(
                  title: 'How to Opt Out',
                  content: '''You can opt out of receiving SMS messages at any time by replying STOP to any message. After you send STOP, you will receive a confirmation message. After that, you will no longer receive SMS messages unless you opt back in.

To opt back in, contact your facility directly or update your preferences in your account settings.''',
                ),
                _PolicySection(
                  title: 'How to Get Help',
                  content: '''If you need help or have questions about SMS messaging, reply HELP to any message. You will receive information about how to contact support.

You can also contact your facility directly or reach out to Storage Facility Creator support through our Contact page.''',
                ),
                _PolicySection(
                  title: 'Who Messages Are From',
                  content: '''SMS messages are sent from Storage Facility Creator on behalf of your facility. Messages will identify the facility name and may include the platform name "Storage Facility Creator" for clarity.

The facility name associated with your account will be included in messages when applicable.''',
                ),
                _PolicySection(
                  title: 'Contact Information',
                  content: '''For questions about this SMS Messaging Policy or to update your preferences, please contact:

• Your facility directly using the contact information provided in your account
• Storage Facility Creator support through our Contact page at /contact
• Email support (if available) through your facility's contact methods''',
                ),
                _PolicySection(
                  title: 'Privacy Policy',
                  content: '''Your phone number and SMS preferences are handled in accordance with our Privacy Policy. We share your phone number with Twilio, our SMS service provider, solely for the purpose of sending and receiving SMS messages.

For more information about how we handle your data, please see our Privacy Policy at /privacy.''',
                ),
                const SizedBox(height: 32),
                const Divider(),
                const SizedBox(height: 24),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => context.go('/privacy'),
                      child: const Text('Privacy Policy'),
                    ),
                    const SizedBox(width: 16),
                    TextButton(
                      onPressed: () => context.go('/terms'),
                      child: const Text('Terms of Service'),
                    ),
                    const SizedBox(width: 16),
                    TextButton(
                      onPressed: () => context.go('/contact'),
                      child: const Text('Contact Us'),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
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

class _PolicySection extends StatelessWidget {
  final String title;
  final String content;

  const _PolicySection({required this.title, required this.content});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 32),
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
          const SizedBox(height: 12),
          Text(
            content,
            style: const TextStyle(
              fontSize: 15,
              height: 1.6,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
