import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Privacy Policy'),
        backgroundColor: AppTheme.primaryBlue,
        foregroundColor: AppTheme.textOnDark,
      ),
      body: const SingleChildScrollView(
        padding: EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Privacy Policy',
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
              '1. Information We Collect',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'We collect information you provide directly to us, such as:\n\n• Account information (email, password)\n• Facility information (name, address, units)\n• Tenant information (name, contact details, payment history)\n• Usage data and analytics',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '2. How We Use Your Information',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'We use the information we collect to:\n\n• Provide and maintain our service\n• Process payments and transactions\n• Send notifications and updates\n• Improve our service and user experience\n• Comply with legal obligations',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '3. Information Sharing',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'We do not sell, trade, or otherwise transfer your personal information to third parties except:\n\n• With your consent\n• To service providers who assist in our operations\n• When required by law or to protect our rights\n• In connection with a business transfer',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '4. Data Security',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'We implement appropriate security measures to protect your personal information against unauthorized access, alteration, disclosure, or destruction. However, no method of transmission over the internet is 100% secure.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '5. Data Retention',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'We retain your information for as long as your account is active or as needed to provide services. We may retain certain information for legitimate business purposes or as required by law.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '6. Your Rights',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'You have the right to:\n\n• Access and update your personal information\n• Delete your account and associated data\n• Opt out of certain communications\n• Request a copy of your data\n• Contact us with privacy concerns',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '7. Cookies and Tracking',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'We may use cookies and similar technologies to enhance your experience, analyze usage patterns, and improve our service. You can control cookie settings through your browser.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '8. SMS Messaging Data',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'When you opt in to receive SMS messages, we collect and store your mobile phone number. This information is used solely for sending SMS notifications, reminders, and account-related communications.\n\n• Phone numbers are shared with Twilio, our SMS service provider, solely for the purpose of sending and receiving SMS messages\n• We store your SMS opt-in status and opt-in date to track consent\n• If you opt out (by replying STOP), we retain your opt-out status to prevent future messages\n• SMS message content and delivery status may be logged for account and support purposes\n• For more details about SMS messaging, including how to opt out, see our SMS Messaging Policy at /sms-policy',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '9. Third-Party Services',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Our service may integrate with third-party services (Firebase, payment processors, Twilio for SMS, SendGrid for email). These services have their own privacy policies, and we are not responsible for their practices.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '10. Children\'s Privacy',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Our service is not intended for children under 13. We do not knowingly collect personal information from children under 13.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '11. Changes to Privacy Policy',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'We may update this Privacy Policy from time to time. We will notify you of any changes by posting the new policy on this page.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 16),
            Text(
              '12. Contact Us',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'If you have any questions about this Privacy Policy, please contact us through the app or our support channels.',
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
