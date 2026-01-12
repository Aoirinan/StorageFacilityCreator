import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../services/email/email_provider.dart';
import '../services/email/rate_limit_queue.dart';

/// Service for managing daily digest emails to reduce email volume
class RemindersDigestService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Queue a reminder for digest sending
  static Future<void> queueReminderForDigest({
    required String facilityId,
    required String tenantId,
    required String templateId,
    required Map<String, dynamic> templateVars,
    required String digestKey, // e.g., 'due', 'overdue', 'maintenance'
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final now = DateTime.now();
      final digestId = '${_formatDate(now)}-$digestKey';
      
      final digestItem = {
        'facilityId': facilityId,
        'tenantId': tenantId,
        'templateId': templateId,
        'templateVars': templateVars,
        'digestKey': digestKey,
        'createdAt': FieldValue.serverTimestamp(),
        'createdByUid': user.uid,
        'processed': false,
      };

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('digests')
          .doc(digestId)
          .collection('items')
          .add(digestItem);

      if (kDebugMode) {
        print('📧 [Digest] Queued reminder for digest: $digestId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Digest] Error queuing reminder: $e');
      }
      rethrow;
    }
  }

  /// Send a digest immediately (combines all items for the digest)
  static Future<DigestSendResult> sendDigestNow({
    required String facilityId,
    required String digestId,
    required RateLimitQueue rateLimitQueue,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      if (kDebugMode) {
        print('📧 [Digest] Sending digest: $digestId for facility: $facilityId');
      }

      // Get all unprocessed items for this digest
      final itemsSnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('digests')
          .doc(digestId)
          .collection('items')
          .where('processed', isEqualTo: false)
          .get();

      if (itemsSnapshot.docs.isEmpty) {
        if (kDebugMode) {
          print('📧 [Digest] No items to process for digest: $digestId');
        }
        return DigestSendResult(emailsSent: 0, itemsProcessed: 0);
      }

      // Group items by tenant
      final itemsByTenant = <String, List<DigestItem>>{};
      final items = itemsSnapshot.docs.map((doc) => DigestItem.fromFirestore(doc)).toList();

      for (final item in items) {
        itemsByTenant.putIfAbsent(item.tenantId, () => []).add(item);
      }

      // Generate and send digest emails
      final emailsToSend = <EmailMessage>[];
      int processedItems = 0;

      for (final entry in itemsByTenant.entries) {
        final tenantId = entry.key;
        final tenantItems = entry.value;

        // Get tenant details
        final tenantDoc = await _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .doc(tenantId)
            .get();

        if (!tenantDoc.exists) {
          if (kDebugMode) {
            print('⚠️ [Digest] Tenant not found: $tenantId');
          }
          continue;
        }

        final tenantData = tenantDoc.data()!;
        final tenantEmail = tenantData['email'] as String?;
        
        if (tenantEmail == null || tenantEmail.isEmpty) {
          if (kDebugMode) {
            print('⚠️ [Digest] No email for tenant: $tenantId');
          }
          continue;
        }

        // Generate digest email content
        final emailContent = _generateDigestEmailContent(
          tenantData['name'] ?? 'Tenant',
          tenantItems,
          digestId,
        );

        final email = EmailMessage(
          to: tenantEmail,
          subject: emailContent.subject,
          html: emailContent.html,
          text: emailContent.text,
        );

        emailsToSend.add(email);
        processedItems += tenantItems.length;
      }

      if (emailsToSend.isNotEmpty) {
        // Send emails through rate-limited queue
        await rateLimitQueue.enqueueBulk(emailsToSend);

        if (kDebugMode) {
          print('📧 [Digest] Queued ${emailsToSend.length} digest emails for sending');
        }
      }

      // Mark all items as processed
      final batch = _firestore.batch();
      for (final item in items) {
        final itemRef = _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('digests')
            .doc(digestId)
            .collection('items')
            .doc(item.id);
        
        batch.update(itemRef, {
          'processed': true,
          'processedAt': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();

      // Update digest metadata
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('digests')
          .doc(digestId)
          .set({
        'facilityId': facilityId,
        'digestId': digestId,
        'sentAt': FieldValue.serverTimestamp(),
        'emailsSent': emailsToSend.length,
        'itemsProcessed': processedItems,
        'createdByUid': user.uid,
      }, SetOptions(merge: true));

      if (kDebugMode) {
        print('✅ [Digest] Digest sent successfully: ${emailsToSend.length} emails, $processedItems items');
      }

      return DigestSendResult(
        emailsSent: emailsToSend.length,
        itemsProcessed: processedItems,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Digest] Error sending digest: $e');
      }
      rethrow;
    }
  }

  /// Generate digest email content
  static DigestEmailContent _generateDigestEmailContent(
    String tenantName,
    List<DigestItem> items,
    String digestId,
  ) {
    final digestKey = digestId.split('-').last;
    final date = digestId.split('-').first;

    String subject;
    switch (digestKey) {
      case 'due':
        subject = 'Rent Due Reminders - ${_formatDisplayDate(date)}';
        break;
      case 'overdue':
        subject = 'Overdue Notices - ${_formatDisplayDate(date)}';
        break;
      case 'maintenance':
        subject = 'Maintenance Reminders - ${_formatDisplayDate(date)}';
        break;
      default:
        subject = 'Reminder Digest - ${_formatDisplayDate(date)}';
    }

    final html = _generateHtmlDigest(tenantName, items, digestKey);
    final text = _generateTextDigest(tenantName, items, digestKey);

    return DigestEmailContent(
      subject: subject,
      html: html,
      text: text,
    );
  }

  static String _generateHtmlDigest(String tenantName, List<DigestItem> items, String digestKey) {
    final buffer = StringBuffer();
    
    buffer.writeln('<!DOCTYPE html>');
    buffer.writeln('<html><head><meta charset="UTF-8"></head><body>');
    buffer.writeln('<h2>Hello $tenantName,</h2>');
    
    switch (digestKey) {
      case 'due':
        buffer.writeln('<p>Here are your upcoming rent due reminders:</p>');
        break;
      case 'overdue':
        buffer.writeln('<p>Here are your overdue notices:</p>');
        break;
      case 'maintenance':
        buffer.writeln('<p>Here are your maintenance reminders:</p>');
        break;
      default:
        buffer.writeln('<p>Here are your reminders:</p>');
    }
    
    buffer.writeln('<ul>');
    for (final item in items) {
      buffer.writeln('<li><strong>${item.templateVars['title'] ?? 'Reminder'}</strong>');
      if (item.templateVars['amount'] != null) {
        buffer.writeln(' - Amount: \$${item.templateVars['amount']}');
      }
      if (item.templateVars['dueDate'] != null) {
        buffer.writeln(' - Due: ${item.templateVars['dueDate']}');
      }
      buffer.writeln('</li>');
    }
    buffer.writeln('</ul>');
    
    buffer.writeln('<p>Please contact us if you have any questions.</p>');
    buffer.writeln('<p>Best regards,<br>Property Management</p>');
    buffer.writeln('</body></html>');
    
    return buffer.toString();
  }

  static String _generateTextDigest(String tenantName, List<DigestItem> items, String digestKey) {
    final buffer = StringBuffer();
    
    buffer.writeln('Hello $tenantName,');
    buffer.writeln();
    
    switch (digestKey) {
      case 'due':
        buffer.writeln('Here are your upcoming rent due reminders:');
        break;
      case 'overdue':
        buffer.writeln('Here are your overdue notices:');
        break;
      case 'maintenance':
        buffer.writeln('Here are your maintenance reminders:');
        break;
      default:
        buffer.writeln('Here are your reminders:');
    }
    
    buffer.writeln();
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      buffer.writeln('${i + 1}. ${item.templateVars['title'] ?? 'Reminder'}');
      if (item.templateVars['amount'] != null) {
        buffer.writeln('   Amount: \$${item.templateVars['amount']}');
      }
      if (item.templateVars['dueDate'] != null) {
        buffer.writeln('   Due: ${item.templateVars['dueDate']}');
      }
      buffer.writeln();
    }
    
    buffer.writeln('Please contact us if you have any questions.');
    buffer.writeln();
    buffer.writeln('Best regards,');
    buffer.writeln('Property Management');
    
    return buffer.toString();
  }

  static String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  static String _formatDisplayDate(String dateString) {
    final parts = dateString.split('-');
    if (parts.length == 3) {
      final year = int.parse(parts[0]);
      final month = int.parse(parts[1]);
      final day = int.parse(parts[2]);
      final date = DateTime(year, month, day);
      return '${date.month}/${date.day}/${date.year}';
    }
    return dateString;
  }
}

/// Digest item model
class DigestItem {
  final String id;
  final String facilityId;
  final String tenantId;
  final String templateId;
  final Map<String, dynamic> templateVars;
  final String digestKey;
  final DateTime createdAt;
  final String createdByUid;
  final bool processed;
  final DateTime? processedAt;

  const DigestItem({
    required this.id,
    required this.facilityId,
    required this.tenantId,
    required this.templateId,
    required this.templateVars,
    required this.digestKey,
    required this.createdAt,
    required this.createdByUid,
    required this.processed,
    this.processedAt,
  });

  factory DigestItem.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return DigestItem(
      id: doc.id,
      facilityId: data['facilityId'] ?? '',
      tenantId: data['tenantId'] ?? '',
      templateId: data['templateId'] ?? '',
      templateVars: Map<String, dynamic>.from(data['templateVars'] ?? {}),
      digestKey: data['digestKey'] ?? '',
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      createdByUid: data['createdByUid'] ?? '',
      processed: data['processed'] ?? false,
      processedAt: data['processedAt'] != null 
          ? (data['processedAt'] as Timestamp).toDate() 
          : null,
    );
  }
}

/// Digest email content
class DigestEmailContent {
  final String subject;
  final String html;
  final String text;

  const DigestEmailContent({
    required this.subject,
    required this.html,
    required this.text,
  });
}

/// Result of sending a digest
class DigestSendResult {
  final int emailsSent;
  final int itemsProcessed;

  const DigestSendResult({
    required this.emailsSent,
    required this.itemsProcessed,
  });
}
