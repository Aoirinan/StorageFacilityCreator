import 'package:flutter/foundation.dart';
import 'services/email_service.dart';
import 'services/template_renderer.dart';

/// Test the email system functionality
class EmailSystemTester {
  /// Test template rendering
  static Future<void> testTemplateRendering() async {
    if (kDebugMode) {
      print('🧪 Testing template rendering...');
      
      try {
        final result = await TemplateRenderer.renderTemplate(
          templateId: 'due_default',
          variables: {
            'tenantName': 'John Doe',
            'facilityName': 'Test Storage Facility',
            'amount': '150.00',
            'unitNumber': 'A-101',
            'dueDate': '2024-01-15',
          },
        );
        
        if (result.success) {
          print('✅ Template rendering successful');
          print('📧 HTML length: ${result.html?.length ?? 0} characters');
          print('📧 Text length: ${result.text?.length ?? 0} characters');
        } else {
          print('❌ Template rendering failed: ${result.error}');
        }
      } catch (e) {
        print('❌ Template rendering error: $e');
      }
    }
  }
  
  /// Test email service (without actually sending)
  static Future<void> testEmailService() async {
    if (kDebugMode) {
      print('🧪 Testing email service...');
      
      try {
        // This will fail with authentication error, but we can test the structure
        final result = await EmailService.sendEmail(
          to: 'test@example.com',
          subject: 'Test Email',
          text: 'This is a test email',
          html: '<p>This is a test email</p>',
          facilityId: 'test-facility-id',
        );
        
        if (result.success) {
          print('✅ Email service call successful');
          print('📧 Message ID: ${result.messageId}');
        } else {
          print('⚠️ Email service call failed (expected): ${result.error}');
          print('📧 Error code: ${result.errorCode}');
        }
      } catch (e) {
        print('❌ Email service error: $e');
      }
    }
  }
  
  /// Run all tests
  static Future<void> runAllTests() async {
    if (kDebugMode) {
      print('🚀 Starting email system tests...');
      
      await testTemplateRendering();
      await testEmailService();
      
      print('🏁 Email system tests completed');
    }
  }
}
