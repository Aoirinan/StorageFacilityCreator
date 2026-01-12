import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'email_provider.dart';

/// Amazon SES email provider implementation
class AmazonSESProvider extends EmailProvider {
  final String accessKeyId;
  final String secretAccessKey;
  final String region;
  final String? fromEmail;
  
  late final String _endpoint;
  late final Map<String, String> _defaultHeaders;

  AmazonSESProvider({
    required this.accessKeyId,
    required this.secretAccessKey,
    required this.region,
    this.fromEmail,
  }) {
    _endpoint = 'https://email.$region.amazonaws.com/';
    _defaultHeaders = {
      'Content-Type': 'application/x-amz-json-1.0',
      'X-Amz-Target': 'AWSSimpleEmailService.SendEmail',
    };
  }

  @override
  String get providerName => 'Amazon SES ($region)';

  /// Create SES provider from environment variables
  factory AmazonSESProvider.fromEnvironment({
    String fromEmailDefault = 'noreply@facility.com',
  }) {
    final accessKey = Platform.environment['SES_ACCESS_KEY'];
    final secretKey = Platform.environment['SES_SECRET_KEY'];
    final region = Platform.environment['SES_REGION'] ?? 'us-east-1';
    final fromEmail = Platform.environment['SES_FROM_EMAIL'] ?? fromEmailDefault;

    if (accessKey == null || secretKey == null) {
      throw Exception('SES_ACCESS_KEY and SES_SECRET_KEY environment variables are required');
    }

    return AmazonSESProvider(
      accessKeyId: accessKey,
      secretAccessKey: secretKey,
      region: region,
      fromEmail: fromEmail,
    );
  }

  @override
  Future<void> sendEmail({
    required String to,
    required String subject,
    String? html,
    String? text,
    String? from,
  }) async {
    final message = EmailMessage(
      to: to,
      subject: subject,
      html: html,
      text: text,
      from: from ?? fromEmail,
    );

    final result = await sendBulk(messages: [message]);
    
    if (!result.isSuccess && result.errors.isNotEmpty) {
      throw Exception('Failed to send email: ${result.errors.first.error}');
    }
  }

  @override
  Future<BulkEmailResult> sendBulk({
    required List<EmailMessage> messages,
  }) async {
    final startTime = DateTime.now();
    final errors = <EmailError>[];
    int sentCount = 0;

    if (kDebugMode) {
      print('📧 [SES] Sending ${messages.length} emails via Amazon SES');
    }

    for (final message in messages) {
      try {
        await _sendSingleEmail(message);
        sentCount++;
        
        if (kDebugMode) {
          print('✅ [SES] Email sent to: ${message.to}');
        }
      } catch (e) {
        final error = EmailError(
          recipient: message.to,
          error: e.toString(),
          timestamp: DateTime.now(),
        );
        errors.add(error);
        
        if (kDebugMode) {
          print('❌ [SES] Failed to send to ${message.to}: $e');
        }
      }
    }

    final processingTime = DateTime.now().difference(startTime);

    if (kDebugMode) {
      print('📧 [SES] Bulk operation completed: $sentCount sent, ${errors.length} failed');
    }

    return BulkEmailResult(
      totalSent: sentCount,
      totalFailed: errors.length,
      errors: errors,
      processingTime: processingTime,
    );
  }

  Future<void> _sendSingleEmail(EmailMessage message) async {
    final payload = _buildSESPayload(message);
    final timestamp = DateTime.now().toUtc().toIso8601String();
    
    final headers = Map<String, String>.from(_defaultHeaders);
    headers['Authorization'] = _buildAuthorizationHeader('POST', '/', timestamp, payload);
    headers['X-Amz-Date'] = '${timestamp.replaceAll(RegExp(r'[-:]'), '').substring(0, 15)}Z';

    final response = await http.post(
      Uri.parse(_endpoint),
      headers: headers,
      body: jsonEncode(payload),
    );

    if (response.statusCode != 200) {
      final errorBody = jsonDecode(response.body);
      throw Exception('SES API error (${response.statusCode}): ${errorBody['message'] ?? response.body}');
    }
  }

  Map<String, dynamic> _buildSESPayload(EmailMessage message) {
    final destination = {
      'ToAddresses': [message.to],
    };

    final messageContent = <String, dynamic>{
      'Subject': {
        'Data': message.subject,
        'Charset': 'UTF-8',
      },
    };

    if (message.text != null && message.html != null) {
      // Both text and HTML
      messageContent['Body'] = {
        'Text': {
          'Data': message.text!,
          'Charset': 'UTF-8',
        },
        'Html': {
          'Data': message.html!,
          'Charset': 'UTF-8',
        },
      };
    } else if (message.text != null) {
      // Text only
      messageContent['Body'] = {
        'Text': {
          'Data': message.text!,
          'Charset': 'UTF-8',
        },
      };
    } else if (message.html != null) {
      // HTML only
      messageContent['Body'] = {
        'Html': {
          'Data': message.html!,
          'Charset': 'UTF-8',
        },
      };
    }

    return {
      'Source': message.from ?? fromEmail,
      'Destination': destination,
      'Message': messageContent,
    };
  }

  String _buildAuthorizationHeader(String method, String path, String timestamp, Map<String, dynamic> payload) {
    final date = timestamp.substring(0, 8);
    final credential = '$accessKeyId/$date/$region/ses/aws4_request';
    
    final canonicalRequest = _buildCanonicalRequest(method, path, timestamp, payload);
    final stringToSign = _buildStringToSign(timestamp, canonicalRequest);
    final signature = _calculateSignature(secretAccessKey, date, region, stringToSign);
    
    return 'AWS4-HMAC-SHA256 Credential=$credential, SignedHeaders=content-type;host;x-amz-date;x-amz-target, Signature=$signature';
  }

  String _buildCanonicalRequest(String method, String path, String timestamp, Map<String, dynamic> payload) {
    final payloadHash = sha256.convert(utf8.encode(jsonEncode(payload))).toString();
    final headers = 'content-type:application/x-amz-json-1.0\nhost:email.${region}.amazonaws.com\nx-amz-date:$timestamp\nx-amz-target:AWSSimpleEmailService.SendEmail';
    final signedHeaders = 'content-type;host;x-amz-date;x-amz-target';
    
    return [
      method,
      path,
      '', // query string
      headers,
      '', // empty line
      signedHeaders,
      payloadHash,
    ].join('\n');
  }

  String _buildStringToSign(String timestamp, String canonicalRequest) {
    final date = timestamp.substring(0, 8);
    final credentialScope = '$date/$region/ses/aws4_request';
    final canonicalRequestHash = sha256.convert(utf8.encode(canonicalRequest)).toString();
    
    return [
      'AWS4-HMAC-SHA256',
      timestamp,
      credentialScope,
      canonicalRequestHash,
    ].join('\n');
  }

  String _calculateSignature(String secretKey, String date, String region, String stringToSign) {
    final kDate = _hmacSha256(utf8.encode('AWS4$secretKey'), date);
    final kRegion = _hmacSha256(kDate, region);
    final kService = _hmacSha256(kRegion, 'ses');
    final kSigning = _hmacSha256(kService, 'aws4_request');
    
    return _hmacSha256(kSigning, stringToSign).map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  }

  List<int> _hmacSha256(List<int> key, String data) {
    final hmac = Hmac(sha256, key);
    return hmac.convert(utf8.encode(data)).bytes;
  }
}
