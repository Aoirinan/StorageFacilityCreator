import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../models/contract_model.dart';
import '../router/app_route.dart';
import '../services/contract_service.dart';
import '../services/email_service.dart';
import '../services/tenant_service.dart';
import '../theme/app_theme.dart';
import '../utils/email_send_feedback.dart';

/// Shared UI + email flows for sending contracts and opening the signing screen.
class ContractSendService {
  ContractSendService._();

  static int get _expiryDays => ContractService.signingTokenTtl.inDays;

  static String buildSigningUrl(String signingToken) {
    if (kIsWeb) {
      final baseUrl = Uri.base.origin;
      return '$baseUrl/#/contracts/sign?token=$signingToken';
    }
    return 'sfcapp://contracts/sign?token=$signingToken';
  }

  static String buildSigningEmailHtml(ContractModel contract, String signingUrl) {
    return '''
      <html>
        <body style="font-family: Arial, sans-serif; line-height: 1.6; color: #333;">
          <div style="max-width: 600px; margin: 0 auto; padding: 20px;">
            <h2 style="color: #7B1FA2;">Contract Signature Required</h2>
            <p>Dear Tenant,</p>
            <p>You have been requested to sign the following contract:</p>
            <div style="background-color: #f5f5f5; padding: 15px; border-radius: 5px; margin: 20px 0;">
              <h3 style="margin-top: 0;">${contract.title}</h3>
              <p><strong>Type:</strong> ${contract.type.displayName}</p>
              <p><strong>Description:</strong> ${contract.description}</p>
            </div>
            <p>Please click the button below to review and sign the contract electronically:</p>
            <div style="text-align: center; margin: 30px 0;">
              <a clicktracking="off" href="$signingUrl" style="background-color: #7B1FA2; color: white; padding: 12px 24px; text-decoration: none; border-radius: 5px; display: inline-block;">
                Sign Contract
              </a>
            </div>
            <p style="font-size: 12px; color: #666;">
              This link will expire in $_expiryDays days. If you have any questions, please contact your facility manager.
            </p>
            <hr style="border: none; border-top: 1px solid #eee; margin: 30px 0;">
            <p style="font-size: 11px; color: #999;">
              This is an automated message. Please do not reply to this email.
            </p>
          </div>
        </body>
      </html>
    ''';
  }

  static String buildSigningEmailText(ContractModel contract, String signingUrl) {
    return '''
Contract Signature Required

Dear Tenant,

You have been requested to sign the following contract:

Title: ${contract.title}
Type: ${contract.type.displayName}
Description: ${contract.description}

Please use the following link to review and sign the contract electronically:

$signingUrl

This link will expire in $_expiryDays days. If you have any questions, please contact your facility manager.

This is an automated message. Please do not reply to this email.
    ''';
  }

  static Future<String?> getTenantEmail(ContractModel contract) async {
    try {
      final tenant =
          await TenantService.getTenantById(contract.facilityId, contract.tenantId);
      final email = tenant?.email?.trim();
      if (email == null || email.isEmpty) return null;
      return email;
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Could not load tenant email: $e');
      }
      return null;
    }
  }

  static Future<void> sendContractForSignature({
    required BuildContext context,
    required ContractModel contract,
    required String sentBy,
    VoidCallback? onComplete,
  }) async {
    final tenantEmail = await getTenantEmail(contract);
    if (tenantEmail == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Tenant email not found. Please add an email address for the tenant.',
            ),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
      return;
    }

    if (!context.mounted) return;
    final shouldSend = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send Contract for Signature'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This will send the contract to the tenant for electronic signature.',
            ),
            const SizedBox(height: 16),
            Text('Recipient: $tenantEmail'),
            const SizedBox(height: 8),
            const Text(
              'The tenant will receive an email with a secure link to sign the contract.',
              style: TextStyle(fontSize: 12, color: AppTheme.textTertiary),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Send'),
          ),
        ],
      ),
    );

    if (shouldSend != true || !context.mounted) return;

    try {
      final signingToken = await ContractService.sendContract(
        facilityId: contract.facilityId,
        contractId: contract.id,
        sentBy: sentBy,
        tenantEmail: tenantEmail,
      );

      final signingUrl = buildSigningUrl(signingToken);
      final emailResult = await EmailService.sendEmail(
        to: tenantEmail,
        subject: 'Contract Signature Required: ${contract.title}',
        html: buildSigningEmailHtml(contract, signingUrl),
        text: buildSigningEmailText(contract, signingUrl),
        facilityId: contract.facilityId,
      );

      if (!context.mounted) return;

      if (emailResult.success) {
        final updated = await ContractService.getContract(
          contract.facilityId,
          contract.id,
        );
        if (!context.mounted) return;
        showContractSentDialog(
          context,
          contract: updated ?? contract,
          signingToken: signingToken,
          signingUrl: signingUrl,
        );
        onComplete?.call();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Contract marked as sent, but email failed. ${EmailService.staffEmailFailureHint(emailResult)}',
            ),
            backgroundColor: recipientUnsubscribedEmailFailure(emailResult)
                ? AppTheme.warning
                : AppTheme.error,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error sending contract: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  static void showContractSentDialog(
    BuildContext context, {
    required ContractModel contract,
    required String signingToken,
    required String signingUrl,
  }) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Contract Sent Successfully!'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('The contract has been sent to the tenant.'),
              const SizedBox(height: 8),
              Text(
                'If the email doesn\'t arrive, check the spam/junk folder. You can also copy the signing link below and send it manually.',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 16),
              const Text(
                'Signing link:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
              const SizedBox(height: 8),
              SelectableText(
                signingUrl,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: AppTheme.primaryBlue,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        openSigningScreen(context, contract, signingToken);
                      },
                      icon: const Icon(Icons.edit, size: 16),
                      label: const Text('Open Signing Screen'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryBlueDark,
                        foregroundColor: AppTheme.textOnDark,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: signingUrl));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Signing link copied! Send it to the tenant if the email didn\'t arrive.',
                        ),
                        backgroundColor: AppTheme.success,
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy signing link'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  static Future<void> resendContractForSignature({
    required BuildContext context,
    required ContractModel contract,
    VoidCallback? onComplete,
  }) async {
    final tenantEmail = await getTenantEmail(contract);
    if (tenantEmail == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Tenant email not found. Please add an email address for the tenant.',
            ),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
      return;
    }

    if (!context.mounted) return;
    final shouldResend = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Resend Contract'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This will send a new signing link to the tenant. The previous link will stop working.',
            ),
            const SizedBox(height: 16),
            Text('Recipient: $tenantEmail'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Resend'),
          ),
        ],
      ),
    );

    if (shouldResend != true || !context.mounted) return;

    try {
      final signingToken = await ContractService.resendContract(
        facilityId: contract.facilityId,
        contractId: contract.id,
      );

      final signingUrl = buildSigningUrl(signingToken);
      final html = buildSigningEmailHtml(contract, signingUrl);
      final text = buildSigningEmailText(contract, signingUrl);

      EmailResult emailResult = await EmailService.sendEmail(
        to: tenantEmail,
        subject: 'Contract Signature Required (Resent): ${contract.title}',
        html: html,
        text: text,
        facilityId: contract.facilityId,
      );
      if (!emailResult.success && context.mounted) {
        await Future.delayed(const Duration(seconds: 2));
        if (context.mounted) {
          emailResult = await EmailService.sendEmail(
            to: tenantEmail,
            subject: 'Contract Signature Required (Resent): ${contract.title}',
            html: html,
            text: text,
            facilityId: contract.facilityId,
          );
        }
      }

      if (!context.mounted) return;

      if (emailResult.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Contract resent successfully. The tenant will receive a new signing link.',
            ),
            backgroundColor: AppTheme.success,
          ),
        );
        onComplete?.call();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(EmailService.staffEmailFailureHint(emailResult)),
            backgroundColor: recipientUnsubscribedEmailFailure(emailResult)
                ? AppTheme.warning
                : AppTheme.error,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error resending contract: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  /// Prepares contract for signing (status sent + token) without emailing, then opens signing UI.
  static Future<bool?> signContractInPerson({
    required BuildContext context,
    required ContractModel contract,
    required String sentBy,
  }) async {
    try {
      final signingToken = await ContractService.sendContract(
        facilityId: contract.facilityId,
        contractId: contract.id,
        sentBy: sentBy,
      );
      final updated = await ContractService.getContract(
        contract.facilityId,
        contract.id,
      );
      if (!context.mounted) return null;
      return openSigningScreen(context, updated ?? contract, signingToken);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error preparing contract for signing: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
      return null;
    }
  }

  static Future<bool?> openSigningScreen(
    BuildContext context,
    ContractModel contract,
    String signingToken,
  ) {
    return context.push<bool>(
      '${AppRoute.contractSign}?token=$signingToken',
      extra: contract,
    );
  }

  static Future<bool?> openSigningScreenFromContract(
    BuildContext context,
    ContractModel contract,
  ) async {
    try {
      final signingToken = await ContractService.getSigningToken(
        facilityId: contract.facilityId,
        contractId: contract.id,
      );
      if (signingToken == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Contract must be sent first to generate a signing link. Use Send or Sign in person.',
              ),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
        return null;
      }
      if (!context.mounted) return null;
      return openSigningScreen(context, contract, signingToken);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error accessing contract: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
      return null;
    }
  }
}
