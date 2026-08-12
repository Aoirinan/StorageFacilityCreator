import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/contract_model.dart';
import '../providers/contract_provider.dart';
import '../providers/auth_provider.dart';
import '../services/tenant_service.dart';
import '../services/contract_send_service.dart';
import '../services/facility_service.dart';
import '../theme/app_theme.dart';
import 'contract_creation_screen.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';
import '../utils/error_message_helper.dart';

class ContractDetailScreen extends ConsumerStatefulWidget {
  final ContractModel contract;
  
  const ContractDetailScreen({super.key, required this.contract});

  @override
  ConsumerState<ContractDetailScreen> createState() => _ContractDetailScreenState();
}

class _ContractDetailScreenState extends ConsumerState<ContractDetailScreen> {
  ContractModel get contract => widget.contract;

  String? _facilityName;
  String? _tenantName;
  String? _tenantEmail;
  final Map<String, String> _userDisplayNames = {};
  bool _partiesLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadPartyDetails();
  }

  Future<void> _loadPartyDetails() async {
    try {
      final facilityFuture = FacilityService.getFacility(contract.facilityId);
      final tenantFuture = TenantService.getTenantById(contract.facilityId, contract.tenantId);

      final facility = await facilityFuture;
      final tenant = await tenantFuture;

      final uidsToResolve = <String>{contract.createdBy};
      if (contract.sentBy != null) uidsToResolve.add(contract.sentBy!);
      if (contract.signedBy != null) uidsToResolve.add(contract.signedBy!);

      final resolvedNames = <String, String>{};
      await Future.wait(uidsToResolve.map((uid) async {
        try {
          final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
          final data = doc.data();
          if (data != null) {
            final name = data['displayName'] as String? ??
                data['name'] as String? ??
                data['email'] as String?;
            if (name != null && name.isNotEmpty) {
              resolvedNames[uid] = name;
            }
          }
        } catch (_) {}
      }));

      if (mounted) {
        setState(() {
          _facilityName = facility?.name;
          _tenantName = tenant?.name;
          _tenantEmail = tenant?.email;
          _userDisplayNames.addAll(resolvedNames);
          _partiesLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _partiesLoaded = true);
    }
  }

  String _resolveUid(String uid) {
    return _userDisplayNames[uid] ?? uid;
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);

    return authState.when(
      data: (user) {
        if (user == null) {
          return const Center(child: Text('Please sign in to view contracts'));
        }

        return SingleChildScrollView(
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
            if (contract.customFields?['onlineMoveInContext'] is Map) ...[
              const SizedBox(height: 24),
              _buildOnlineMoveInContextSection(
                context,
                Map<String, dynamic>.from(
                  contract.customFields!['onlineMoveInContext'] as Map,
                ),
              ),
            ],
            const SizedBox(height: 24),
            
            // Parties Information
            _buildSection(context, 'Parties', [
              _buildInfoRow(
                'Facility',
                _facilityName ?? (_partiesLoaded ? contract.facilityId : '...'),
              ),
              _buildInfoRow(
                'Tenant',
                _tenantName != null
                    ? (_tenantEmail != null ? '$_tenantName ($_tenantEmail)' : _tenantName!)
                    : (_partiesLoaded ? contract.tenantId : '...'),
              ),
              _buildInfoRow(
                'Created By',
                _partiesLoaded ? _resolveUid(contract.createdBy) : '...',
              ),
              if (contract.sentBy != null)
                _buildInfoRow(
                  'Sent By',
                  _partiesLoaded ? _resolveUid(contract.sentBy!) : '...',
                ),
              if (contract.signedBy != null)
                _buildInfoRow(
                  'Signed By',
                  _partiesLoaded ? _resolveUid(contract.signedBy!) : '...',
                ),
            ]),
            const SizedBox(height: 24),
            
            // Timeline Information
            _buildSection(context, 'Timeline', [
              _buildInfoRow('Created', _formatDateTime(contract.createdAt)),
              if (contract.sentAt != null)
                _buildInfoRow('Sent', _formatDateTime(contract.sentAt!)),
              if (contract.signedAt != null)
                _buildInfoRow('Signed', _formatDateTime(contract.signedAt!)),
              if (contract.expiresAt != null)
                _buildInfoRow(
                  'Expires', 
                  _formatDateTime(contract.expiresAt!),
                  isExpired: contract.expiresAt!.isBefore(DateTime.now()),
                ),
            ]),
            const SizedBox(height: 24),

            // Signed agreement: PDF links and/or online move-in signature preview
            if (contract.status == ContractStatus.signed) ...[
              if (contract.fileUrl != null || contract.signedFileUrl != null)
                _buildSection(context, 'Files', [
                  if (contract.fileUrl != null)
                    _buildFileRow(context, 'Contract File', contract.fileUrl!, 'View Contract'),
                  if (contract.signedFileUrl != null)
                    _buildFileRow(
                      context,
                      'Signed agreement (PDF)',
                      contract.signedFileUrl!,
                      'View signed PDF',
                    ),
                ])
              else
                _buildOnlineMoveInSignatureSection(context),
              const SizedBox(height: 24),
            ] else if (contract.fileUrl != null || contract.signedFileUrl != null) ...[
              _buildSection(context, 'Files', [
                if (contract.fileUrl != null)
                  _buildFileRow(context, 'Contract File', contract.fileUrl!, 'View Contract'),
                if (contract.signedFileUrl != null)
                  _buildFileRow(context, 'Signed File', contract.signedFileUrl!, 'View Signed Contract'),
              ]),
              const SizedBox(height: 24),
            ],
            
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
      );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) => Center(
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

  Widget _buildOnlineMoveInContextSection(
    BuildContext context,
    Map<String, dynamic> ctx,
  ) {
    String? pick(String k) {
      final v = ctx[k];
      if (v == null) return null;
      final s = v.toString().trim();
      return s.isEmpty ? null : s;
    }

    final rows = <Widget>[
      _buildInfoRow('Unit number', pick('unitNumber') ?? '—'),
      if (pick('unitTypeDisplay') != null)
        _buildInfoRow('Unit type', pick('unitTypeDisplay')!),
      if (pick('unitDescription') != null)
        _buildInfoRow('Unit description', pick('unitDescription')!),
      if (pick('facilityName') != null)
        _buildInfoRow('Facility name', pick('facilityName')!),
      if (pick('facilityAddress') != null)
        _buildInfoRow('Facility address', pick('facilityAddress')!),
      if (pick('facilityPhone') != null)
        _buildInfoRow('Facility phone', pick('facilityPhone')!),
      if (pick('facilityEmail') != null)
        _buildInfoRow('Facility email', pick('facilityEmail')!),
    ];

    return _buildSection(context, 'Online move-in details', rows);
  }

  /// Online move-ins stored a PNG signature in customFields before PDF upload existed.
  Widget _buildOnlineMoveInSignatureSection(BuildContext context) {
    final raw = contract.customFields?['publicMoveInSignature'];
    if (raw is! Map) {
      return _buildSection(
        context,
        'Signed agreement',
        [
          Text(
            'There is no PDF or signature image stored for this contract. '
            'If this was an older online move-in, only the summary above was saved.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      );
    }
    final map = Map<String, dynamic>.from(raw);
    final b64 = map['signaturePngBase64'] as String?;
    if (b64 == null || b64.isEmpty) {
      return _buildSection(
        context,
        'Signed agreement',
        [
          Text(
            'Signature data is missing on this record.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      );
    }
    late final Uint8List bytes;
    try {
      bytes = base64Decode(b64);
    } catch (_) {
      return _buildSection(
        context,
        'Signed agreement',
        [
          const Text('Could not decode the stored signature image.'),
        ],
      );
    }
    final signedAt = map['signedAt']?.toString() ?? '';
    final signerName = map['signerName']?.toString() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Signed agreement',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: AppTheme.primaryBlueDark,
              ),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.backgroundLight,
            border: Border.all(color: AppTheme.borderLight),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Electronic signature (online move-in)',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              if (signerName.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Signer: $signerName'),
              ],
              if (signedAt.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('Signed at: $signedAt'),
              ],
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Text('Unable to display image'),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'New online move-ins also generate a PDF copy you can open with “View signed PDF” above when available.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static const _internalCustomFieldKeys = {
    'signers',
    'signaturePlaceholders',
    'templateSigners',
    'signaturePlaceholderDers',
    'requiredFields',
    'defaultValues',
    'templateId',
    'facilityOwnerUid',
  };

  Widget _buildCustomFieldsSection(BuildContext context, Map<String, dynamic> customFields) {
    final visibleEntries = customFields.entries
        .where((e) =>
            !_internalCustomFieldKeys.contains(e.key) &&
            e.value != null &&
            e.value.toString().isNotEmpty &&
            e.value is! List &&
            e.value is! Map)
        .toList();

    if (visibleEntries.isEmpty) return const SizedBox.shrink();

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
            children: visibleEntries.map((entry) {
              return _buildInfoRow(entry.key, entry.value.toString());
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
        if (contract.status == ContractStatus.draft) ...[
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () => _signContractInPerson(context, ref),
              icon: const Icon(Icons.draw),
              label: const Text('Sign in person'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.success,
                foregroundColor: AppTheme.textOnDark,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 16),
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
        ],
        if (contract.status == ContractStatus.sent) ...[
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _resendContract(context, ref),
              icon: const Icon(Icons.refresh),
              label: const Text('Resend Contract'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 16),
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

  String _formatDateTime(DateTime date) {
    final hour = date.hour == 0
        ? 12
        : date.hour > 12
            ? date.hour - 12
            : date.hour;
    final minute = date.minute.toString().padLeft(2, '0');
    final period = date.hour < 12 ? 'AM' : 'PM';
    return '${date.month}/${date.day}/${date.year} at $hour:$minute $period';
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
      case 'sign_in_person':
        _signContractInPerson(context, ref);
        break;
      case 'resend':
        _resendContract(context, ref);
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
    await ContractSendService.sendContractForSignature(
      context: context,
      contract: contract,
      sentBy: ref.read(authStateProvider).value?.uid ?? '',
      onComplete: () => ref.invalidate(contractsProvider(contract.facilityId)),
    );
  }

  Future<void> _resendContract(BuildContext context, WidgetRef ref) async {
    await ContractSendService.resendContractForSignature(
      context: context,
      contract: contract,
      onComplete: () => ref.invalidate(contractsProvider(contract.facilityId)),
    );
  }

  Future<void> _signContractInPerson(BuildContext context, WidgetRef ref) async {
    final signed = await ContractSendService.signContractInPerson(
      context: context,
      contract: contract,
      sentBy: ref.read(authStateProvider).value?.uid ?? '',
    );
    if (signed == true && context.mounted) {
      ref.invalidate(contractsProvider(contract.facilityId));
    }
  }

  Future<void> _signContract(BuildContext context, WidgetRef ref) async {
    final signed = await ContractSendService.openSigningScreenFromContract(
      context,
      contract,
    );
    if (signed == true && context.mounted) {
      ref.invalidate(contractsProvider(contract.facilityId));
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
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
