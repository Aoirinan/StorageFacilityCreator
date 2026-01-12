import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/contract_model.dart';
import '../providers/contract_provider.dart';
import '../providers/auth_provider.dart';
import '../services/contract_service.dart';
import '../services/email_service.dart';
import '../services/tenant_service.dart';
import '../theme/app_theme.dart';
import 'contract_signing_screen.dart';
import 'contract_creation_screen.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';
import '../utils/error_message_helper.dart';

class ContractDetailScreen extends ConsumerWidget {
  final ContractModel contract;
  
  const ContractDetailScreen({super.key, required this.contract});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateProvider);

    return authState.when(
      data: (user) {
        if (user == null) {
          return const Scaffold(
            body: Center(child: Text('Please sign in to view contracts')),
          );
        }

        return ModernPageWrapper(
          currentRoute: '/contracts',
          title: contract.title,
          onNavigate: (route) {
            ModernNavigationService.navigateToRoute(context, route);
          },
          actions: [
            PopupMenuButton<String>(
              onSelected: (value) => _handleAction(context, ref, value),
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'edit',
                  child: Text('Edit'),
                ),
                if (contract.status == ContractStatus.draft)
                  const PopupMenuItem(
                    value: 'send',
                    child: Text('Send'),
                  ),
                if (contract.status == ContractStatus.sent)
                  const PopupMenuItem(
                    value: 'sign',
                    child: Text('Sign'),
                  ),
                if (contract.status == ContractStatus.signed)
                  const PopupMenuItem(
                    value: 'download',
                    child: Text('Download'),
                  ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Text('Delete'),
                ),
              ],
            ),
          ],
          child: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status and Type Header
            _buildStatusHeader(context),
            const SizedBox(height: 24),
            
            // Basic Information
            _buildSection(context, 'Basic Information', [
              _buildInfoRow('Title', contract.title),
              _buildInfoRow('Description', contract.description),
              _buildInfoRow('Type', contract.type.displayName),
              _buildInfoRow('Status', contract.status.displayName),
              _buildInfoRow('Created', _formatDate(contract.createdAt)),
            ]),
            const SizedBox(height: 24),
            
            // Parties Information
            _buildSection(context, 'Parties', [
              _buildInfoRow('Facility ID', contract.facilityId),
              _buildInfoRow('Tenant ID', contract.tenantId),
              _buildInfoRow('Created By', contract.createdBy),
              if (contract.sentBy != null)
                _buildInfoRow('Sent By', contract.sentBy!),
              if (contract.signedBy != null)
                _buildInfoRow('Signed By', contract.signedBy!),
            ]),
            const SizedBox(height: 24),
            
            // Timeline Information
            _buildSection(context, 'Timeline', [
              _buildInfoRow('Created', _formatDate(contract.createdAt)),
              if (contract.sentAt != null)
                _buildInfoRow('Sent', _formatDate(contract.sentAt!)),
              if (contract.signedAt != null)
                _buildInfoRow('Signed', _formatDate(contract.signedAt!)),
              if (contract.expiresAt != null)
                _buildInfoRow(
                  'Expires', 
                  _formatDate(contract.expiresAt!),
                  isExpired: contract.expiresAt!.isBefore(DateTime.now()),
                ),
            ]),
            const SizedBox(height: 24),
            
            // Files Information
            if (contract.fileUrl != null || contract.signedFileUrl != null)
              _buildSection(context, 'Files', [
                if (contract.fileUrl != null)
                  _buildFileRow(context, 'Contract File', contract.fileUrl!, 'View Contract'),
                if (contract.signedFileUrl != null)
                  _buildFileRow(context, 'Signed File', contract.signedFileUrl!, 'View Signed Contract'),
              ]),
            
            // Custom Fields
            if (contract.customFields != null && contract.customFields!.isNotEmpty)
              _buildCustomFieldsSection(context, contract.customFields!),
            
            // Notes
            if (contract.notes != null && contract.notes!.isNotEmpty)
              _buildSection(context, 'Notes', [
                _buildInfoRow('Notes', contract.notes!),
              ]),
            
            const SizedBox(height: 32),
            
            // Action Buttons
            _buildActionButtons(context, ref),
          ],
        ),
      ),
        );
      },
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stackTrace) => Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error, size: 64, color: AppTheme.error),
              const SizedBox(height: 16),
              const Text('Error loading contract'),
              const SizedBox(height: 8),
              Text(ErrorMessageHelper.getUserFriendlyMessage(error)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _getStatusColor(contract.status).withOpacity(0.1),
        border: Border.all(color: _getStatusColor(contract.status)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            _getStatusIcon(contract.status),
            color: _getStatusColor(contract.status),
            size: 32,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  contract.status.displayName,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: _getStatusColor(contract.status),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  contract.type.displayName,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(BuildContext context, String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: AppTheme.primaryBlueDark,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.backgroundLight,
            border: Border.all(color: AppTheme.borderLight),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: children,
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value, {bool isExpired = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: isExpired ? AppTheme.error : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileRow(BuildContext context, String label, String url, String buttonText) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () => _openFile(context, url),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(buttonText),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryBlueDark,
                foregroundColor: AppTheme.textOnDark,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCustomFieldsSection(BuildContext context, Map<String, dynamic> customFields) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Custom Fields',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: AppTheme.primaryBlueDark,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.backgroundLight,
            border: Border.all(color: AppTheme.borderLight),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: customFields.entries.map((entry) {
              return _buildInfoRow(
                entry.key,
                entry.value.toString(),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildActionButtons(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back),
            label: const Text('Back'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        const SizedBox(width: 16),
        if (contract.status == ContractStatus.draft)
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () => _sendContract(context, ref),
              icon: const Icon(Icons.send),
              label: const Text('Send'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.warning,
                foregroundColor: AppTheme.textOnDark,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        if (contract.status == ContractStatus.sent)
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () => _signContract(context, ref),
              icon: const Icon(Icons.edit),
              label: const Text('Sign'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.success,
                foregroundColor: AppTheme.textOnDark,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
      ],
    );
  }

  Color _getStatusColor(ContractStatus status) {
    switch (status) {
      case ContractStatus.draft:
        return AppTheme.textTertiary;
      case ContractStatus.sent:
        return AppTheme.warning;
      case ContractStatus.signed:
        return AppTheme.success;
      case ContractStatus.expired:
        return AppTheme.error;
      case ContractStatus.cancelled:
        return AppTheme.error;
    }
  }

  IconData _getStatusIcon(ContractStatus status) {
    switch (status) {
      case ContractStatus.draft:
        return Icons.edit;
      case ContractStatus.sent:
        return Icons.send;
      case ContractStatus.signed:
        return Icons.check;
      case ContractStatus.expired:
        return Icons.schedule;
      case ContractStatus.cancelled:
        return Icons.cancel;
    }
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }

  Future<void> _openFile(BuildContext context, String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not open file. Please check the URL.'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error opening file: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  void _handleAction(BuildContext context, WidgetRef ref, String action) {
    switch (action) {
      case 'edit':
        _navigateToEditContract(context, ref);
        break;
      case 'send':
        _sendContract(context, ref);
        break;
      case 'sign':
        _signContract(context, ref);
        break;
      case 'download':
        _downloadContract(context);
        break;
      case 'delete':
        _deleteContract(context, ref);
        break;
    }
  }

  void _navigateToEditContract(BuildContext context, WidgetRef ref) {
    // Navigate to contract detail screen - edit functionality can be added there
    // For now, show a message that editing is available through the creation screen
    // In the future, we can add an edit mode to ContractCreationScreen
    context.push(
      '${AppRoute.contractCreate}?facilityId=${contract.facilityId}',
      extra: ContractCreationScreen(
        facilityId: contract.facilityId,
        contract: contract,
      ),
    ).then((_) {
      // Refresh contract data when returning
      if (context.mounted) {
        ref.invalidate(contractsProvider(contract.facilityId));
      }
    });
  }

  Future<void> _sendContract(BuildContext context, WidgetRef ref) async {
    // Get tenant email
    String? tenantEmail;
    try {
      final tenant = await TenantService.getTenantById(contract.facilityId, contract.tenantId);
      tenantEmail = tenant?.email;
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Could not load tenant email: $e');
      }
    }

    if (tenantEmail == null || tenantEmail.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tenant email not found. Please add an email address for the tenant.'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    // Show confirmation dialog
    final shouldSend = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send Contract for Signature'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('This will send the contract to the tenant for electronic signature.'),
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

    if (shouldSend != true) return;

    // Send contract and generate signing token
    try {
      await ContractService.sendContract(
        facilityId: contract.facilityId,
        contractId: contract.id,
        sentBy: ref.read(authStateProvider).value?.uid ?? '',
        tenantEmail: tenantEmail,
      );

      // Get the signing token (we'll need to fetch the contract again or store it)
      final updatedContract = await ContractService.getContract(contract.facilityId, contract.id);
      if (updatedContract == null) {
        throw Exception('Could not retrieve contract after sending');
      }

      // Get signing token from Firestore
      final contractDoc = await FirebaseFirestore.instance
          .collection('facilities')
          .doc(contract.facilityId)
          .collection('contracts')
          .doc(contract.id)
          .get();
      
      final signingToken = contractDoc.data()?['signingToken'] as String?;
      if (signingToken == null) {
        throw Exception('Signing token not generated');
      }

      // Generate signing URL (in production, this would be a proper URL)
      // For now, we'll construct a deep link or web URL
      final signingUrl = _generateSigningUrl(signingToken);

      // Send email with signing link
      final emailResult = await EmailService.sendEmail(
        to: tenantEmail,
        subject: 'Contract Signature Required: ${contract.title}',
        html: _generateSigningEmailHtml(contract, signingUrl),
        text: _generateSigningEmailText(contract, signingUrl),
        facilityId: contract.facilityId,
      );

      if (emailResult.success) {
        // Show dialog with signing link for testing
        showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Contract Sent Successfully!'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('The contract has been sent to the tenant.'),
                  const SizedBox(height: 16),
                  const Text(
                    'Signing Token (for testing):',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    signingToken,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      backgroundColor: AppTheme.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Test URL:',
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
                            context.push('${AppRoute.contractSign}?token=$signingToken');
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
                  OutlinedButton.icon(
                    onPressed: () {
                      // Copy URL to clipboard
                      Clipboard.setData(ClipboardData(text: signingUrl));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('URL copied to clipboard! Paste it in a new browser tab.'),
                          backgroundColor: AppTheme.success,
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy URL'),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            ),
          );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Contract marked as sent, but email failed: ${emailResult.error}'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error sending contract: $e'),
          backgroundColor: AppTheme.error,
        ),
      );
    }
  }

  String _generateSigningUrl(String signingToken) {
    // In production, this should be a proper web URL pointing to your app
    // For web apps, this could be: https://yourapp.com/sign-contract?token=$signingToken
    // For mobile apps, use deep links: sfcapp://sign-contract?token=$signingToken
    // 
    // NOTE: The actual URL needs to be configured based on your deployment.
    // This is a placeholder that should be replaced with your actual app URL.
    if (kIsWeb) {
      // For web, construct a full URL
      final baseUrl = Uri.base.origin;
      return '$baseUrl/sign-contract?token=$signingToken';
    } else {
      // For mobile, use deep link
      return 'sfcapp://sign-contract?token=$signingToken';
    }
  }

  String _generateSigningEmailHtml(ContractModel contract, String signingUrl) {
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
              <a href="$signingUrl" style="background-color: #7B1FA2; color: white; padding: 12px 24px; text-decoration: none; border-radius: 5px; display: inline-block;">
                Sign Contract
              </a>
            </div>
            <p style="font-size: 12px; color: #666;">
              This link will expire in 30 days. If you have any questions, please contact your facility manager.
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

  String _generateSigningEmailText(ContractModel contract, String signingUrl) {
    return '''
Contract Signature Required

Dear Tenant,

You have been requested to sign the following contract:

Title: ${contract.title}
Type: ${contract.type.displayName}
Description: ${contract.description}

Please use the following link to review and sign the contract electronically:

$signingUrl

This link will expire in 30 days. If you have any questions, please contact your facility manager.

This is an automated message. Please do not reply to this email.
    ''';
  }

  Future<void> _signContract(BuildContext context, WidgetRef ref) async {
    // Check if contract has a signing token
    try {
      final contractDoc = await FirebaseFirestore.instance
          .collection('facilities')
          .doc(contract.facilityId)
          .collection('contracts')
          .doc(contract.id)
          .get();

      final signingToken = contractDoc.data()?['signingToken'] as String?;
      if (signingToken == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Contract must be sent first to generate a signing link. Please use "Send Contract" option.'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
        return;
      }

      // Navigate to signing screen
      if (context.mounted) {
        context.push('${AppRoute.contractSign}?token=$signingToken');
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error accessing contract: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _downloadContract(BuildContext context) async {
    if (contract.signedFileUrl == null && contract.fileUrl == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No contract file available for download.'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    final urlToDownload = contract.signedFileUrl ?? contract.fileUrl;
    if (urlToDownload == null) return;

    try {
      final uri = Uri.parse(urlToDownload);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        throw Exception('Could not open URL');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error opening contract: $e'),
          backgroundColor: AppTheme.error,
        ),
      );
    }
  }

  void _deleteContract(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Contract'),
        content: const Text('Are you sure you want to delete this contract?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              ref.read(contractOperationsProvider.notifier).deleteContract(contract.facilityId, contract.id);
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
