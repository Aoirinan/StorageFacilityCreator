import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';

class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Terms of Service'),
        backgroundColor: AppTheme.primaryBlue,
        foregroundColor: AppTheme.textOnDark,
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
              'Last updated: January 28, 2026',
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
              '8. Limitation of Liability',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'The service is provided "as is" without warranties of any kind. We shall not be liable for any indirect, incidental, special, or consequential damages.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '9. Termination',
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
              '10. Changes to Terms',
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
              '11. Contact Information',
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
