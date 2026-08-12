import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';

class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

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
          'Terms of Service',
          style: theme.textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: cs.outlineVariant),
        ),
      ),
      body: const SingleChildScrollView(
        padding: EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Terms of Service',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 16),
            Text(
              'Last updated: July 13, 2026',
              style: TextStyle(
                fontSize: 14,
                color: AppTheme.textSecondary,
              ),
            ),
            SizedBox(height: 24),
            Text(
              '1. Acceptance of Terms',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'By creating an account with Storage Facility Creator (SFC), you agree to be bound by these Terms of Service and all applicable laws and regulations.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '2. Description of Service',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Storage Facility Creator is a comprehensive facility management application that helps storage facility owners manage their properties, tenants, payments, and operations.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '3. User Accounts',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'You are responsible for maintaining the confidentiality of your account credentials and for all activities that occur under your account. You agree to immediately notify us of any unauthorized use of your account.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '4. Acceptable Use',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'You agree to use the service only for lawful purposes and in accordance with these Terms. You may not:\n\n• Use the service for any illegal activities\n• Attempt to gain unauthorized access to other accounts\n• Upload malicious content or viruses\n• Violate any applicable laws or regulations',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '5. Data and Privacy',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Your privacy is important to us. Please review our Privacy Policy to understand how we collect, use, and protect your information.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '6. SMS Messaging Terms',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'If you send SMS messages to tenants through Storage Facility Creator, you are responsible for obtaining proper consent from recipients before sending messages. You agree to:\n\n• Only send SMS messages to tenants who have opted in\n• Respect opt-out requests (STOP keyword) immediately\n• Include required compliance language in your messages\n• Comply with all applicable SMS messaging laws and regulations\n• Not use SMS messaging for spam, harassment, or illegal purposes\n\nStorage Facility Creator provides SMS messaging functionality, but you are responsible for ensuring compliance with carrier requirements and applicable laws. For details about SMS compliance requirements, see our SMS Messaging Policy at /sms-policy.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '7. Payment Terms',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Payment processing is handled through third-party providers. You agree to comply with their terms and conditions. We are not responsible for payment processing errors or disputes.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '8. Do Not Rent Entries',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'If you use the Do Not Rent (DNR) features, you are solely responsible for the entries you or your staff submit. Entries must be factual, based on your facility\'s direct business experience, supported by your internal records, and lawful to share. You must not create entries based on race, color, religion, national origin, sex, familial status, disability, age, or any other protected characteristic, and you must promptly correct or deactivate entries you learn are inaccurate or unsupported.\n\nEntries created by other customers are provided "as is"; Storage Facility Creator does not verify, endorse, or adopt them. Storage Facility Creator is not a consumer reporting agency and DNR entries are not consumer reports under the Fair Credit Reporting Act. See the Do Not Rent Data Policy on our website for entry requirements and the dispute and correction process.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '9. Limitation of Liability',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'The service is provided "as is" and "as available" without warranties of any kind, express or implied, including warranties of merchantability, fitness for a particular purpose, and non-infringement, to the maximum extent permitted by applicable law. We shall not be liable for any indirect, incidental, special, consequential, or punitive damages, including loss of profits, data, or business opportunities. Our total aggregate liability for any claim arising from the service is limited to the amount you paid us in the twelve (12) months preceding the claim. Some jurisdictions do not allow these limitations; in such cases, our liability is limited to the maximum extent permitted.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '10. Indemnification',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'You agree to indemnify and hold harmless Storage Facility Creator and its officers, employees, and agents from any claims, damages, losses, or expenses (including reasonable attorneys\' fees) arising from: (a) your use of the service in violation of these terms; (b) your violation of applicable law; (c) your customer data, including Do Not Rent entries submitted by you or your staff; or (d) your messaging activities, including any failure to obtain required consents.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '11. Termination',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'We may terminate or suspend your account at any time for violations of these terms. You may also terminate your account at any time.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '12. Changes to Terms',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'We reserve the right to modify these terms at any time. Changes will be effective immediately upon posting. Your continued use constitutes acceptance of the modified terms.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '13. Contact Information',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'If you have any questions about these Terms of Service, please contact us through the app or our support channels.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
