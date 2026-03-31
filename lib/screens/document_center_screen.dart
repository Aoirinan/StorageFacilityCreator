import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../models/document_attachment_model.dart';
import '../models/tenant_model.dart';
import '../services/document_service.dart';
import '../services/tenant_service.dart';
import '../services/facility_service.dart';
import '../services/email_service.dart';
import '../providers/auth_provider.dart';
import '../providers/facility_provider.dart';
import '../providers/tenant_provider.dart';
import '../services/modern_navigation_service.dart';
import '../utils/email_send_feedback.dart';

/// Centralized document center screen
class DocumentCenterScreen extends ConsumerStatefulWidget {
  final String? facilityId;
  final String? tenantId; // Optional: filter to specific tenant
  final DocumentCategory? category; // Optional: filter by category

  const DocumentCenterScreen({
    super.key,
    this.facilityId,
    this.tenantId,
    this.category,
  });

  @override
  ConsumerState<DocumentCenterScreen> createState() => _DocumentCenterScreenState();
}

class _DocumentCenterScreenState extends ConsumerState<DocumentCenterScreen> {
  String? _selectedFacilityId;
  DocumentCategory? _selectedCategory;
  DocumentType? _selectedType;
  String? _searchQuery;

  @override
  void initState() {
    super.initState();
    _selectedFacilityId = widget.facilityId;
    _selectedCategory = widget.category;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_selectedFacilityId != null) {
      // Documents will load via stream
    } else {
      _loadUserFacilities();
    }
  }

  Future<void> _loadUserFacilities() async {
    final authState = ref.read(authStateProvider);
    authState.whenData((user) {
      if (user != null && mounted) {
        ref.read(userFacilitiesProvider(user.uid).future).then((facilities) {
          if (facilities.isNotEmpty && mounted) {
            setState(() {
              _selectedFacilityId = facilities.first.id;
            });
          }
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final currentRoute = '/documents';
    
    return ModernPageWrapper(
      currentRoute: currentRoute,
      title: 'Document Center',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      actions: [
        IconButton(
          icon: const Icon(Icons.upload_file),
          onPressed: () => _showUploadDialog(),
          tooltip: 'Upload Document',
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: () {
            setState(() {}); // Trigger rebuild to refresh stream
          },
          tooltip: 'Refresh',
        ),
      ],
      child: Column(
        children: [
          // Facility Selector
          if (widget.facilityId == null) _buildFacilitySelector(),
          // Filters
          _buildFilters(),
          const Divider(),
          // Documents List
          Expanded(
            child: _selectedFacilityId == null
                ? const Center(child: Text('Please select a facility'))
                : _buildDocumentsList(),
          ),
        ],
      ),
    );
  }

  Widget _buildFacilitySelector() {
    final authState = ref.watch(authStateProvider);
    return authState.when(
      data: (user) {
        if (user == null) return const SizedBox.shrink();
        
        final facilitiesAsync = ref.watch(userFacilitiesProvider(user.uid));
        return facilitiesAsync.when(
          data: (facilities) {
            if (facilities.isEmpty) return const SizedBox.shrink();
            
            return Container(
              padding: const EdgeInsets.all(16),
              child: DropdownButtonFormField<String>(
                value: _selectedFacilityId,
                decoration: const InputDecoration(
                  labelText: 'Facility',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.business),
                ),
                items: facilities.map((facility) {
                  return DropdownMenuItem<String>(
                    value: facility.id,
                    child: Text(facility.name),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null && value != _selectedFacilityId) {
                    setState(() {
                      _selectedFacilityId = value;
                    });
                  }
                },
              ),
            );
          },
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: LinearProgressIndicator(),
          ),
          error: (_, __) => const SizedBox.shrink(),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _buildFilters() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Search
          TextField(
            decoration: InputDecoration(
              labelText: 'Search documents',
              hintText: 'Search by name, description...',
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              suffixIcon: _searchQuery != null && _searchQuery!.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        setState(() {
                          _searchQuery = null;
                        });
                      },
                    )
                  : null,
            ),
            onChanged: (value) {
              setState(() {
                _searchQuery = value.isEmpty ? null : value;
              });
            },
          ),
          const SizedBox(height: 16),
          // Category and Type Filters
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<DocumentCategory?>(
                  value: _selectedCategory,
                  decoration: const InputDecoration(
                    labelText: 'Category',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.category),
                  ),
                  items: [
                    const DropdownMenuItem<DocumentCategory?>(
                      value: null,
                      child: Text('All Categories'),
                    ),
                    ...DocumentCategory.values.map((cat) {
                      return DropdownMenuItem<DocumentCategory?>(
                        value: cat,
                        child: Text(_getCategoryLabel(cat)),
                      );
                    }),
                  ],
                  onChanged: (value) {
                    setState(() {
                      _selectedCategory = value;
                    });
                  },
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: DropdownButtonFormField<DocumentType?>(
                  value: _selectedType,
                  decoration: const InputDecoration(
                    labelText: 'Type',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.description),
                  ),
                  items: [
                    const DropdownMenuItem<DocumentType?>(
                      value: null,
                      child: Text('All Types'),
                    ),
                    ...DocumentType.values.map((type) {
                      return DropdownMenuItem<DocumentType?>(
                        value: type,
                        child: Text(_getTypeLabel(type)),
                      );
                    }),
                  ],
                  onChanged: (value) {
                    setState(() {
                      _selectedType = value;
                    });
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDocumentsList() {
    return StreamBuilder<List<DocumentAttachment>>(
      stream: DocumentService.getDocumentsForFacilityStream(
        _selectedFacilityId!,
        tenantId: widget.tenantId,
        category: _selectedCategory?.name,
        documentType: _selectedType,
      ),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(
            child: Text('Error loading documents: ${snapshot.error}'),
          );
        }

        final documents = snapshot.data ?? [];
        final filteredDocuments = _searchQuery != null && _searchQuery!.isNotEmpty
            ? documents.where((doc) {
                final query = _searchQuery!.toLowerCase();
                return doc.fileName.toLowerCase().contains(query) ||
                    (doc.description?.toLowerCase().contains(query) ?? false);
              }).toList()
            : documents;

        if (filteredDocuments.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.folder_outlined, size: 64, color: AppTheme.textTertiary),
                const SizedBox(height: 16),
                Text(
                  'No documents found',
                  style: TextStyle(
                    fontSize: 18,
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: _showUploadDialog,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Upload First Document'),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: filteredDocuments.length,
          itemBuilder: (context, index) {
            return _buildDocumentCard(filteredDocuments[index]);
          },
        );
      },
    );
  }

  Widget _buildDocumentCard(DocumentAttachment document) {
    final icon = _getDocumentIcon(document.documentType);
    final color = _getDocumentColor(document.documentType);
    final sizeText = _formatFileSize(document.fileSize);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withOpacity(0.1),
          child: Icon(icon, color: color),
        ),
        title: Text(
          document.fileName,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            if (document.description != null && document.description!.isNotEmpty)
              Text(
                document.description!,
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                Chip(
                  label: Text(
                    _getTypeLabel(document.documentType),
                    style: TextStyle(fontSize: 11),
                  ),
                  backgroundColor: color.withOpacity(0.1),
                ),
                Chip(
                  label: Text(
                    _getCategoryLabel(document.category),
                    style: TextStyle(fontSize: 11),
                  ),
                  backgroundColor: AppTheme.backgroundLight,
                ),
                Text(
                  sizeText,
                  style: TextStyle(fontSize: 11, color: AppTheme.textTertiary),
                ),
                Text(
                  DateFormat('MMM d, yyyy').format(document.uploadedAt),
                  style: TextStyle(fontSize: 11, color: AppTheme.textTertiary),
                ),
              ],
            ),
          ],
        ),
        trailing: PopupMenuButton(
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'view',
              child: Row(
                children: [
                  Icon(Icons.open_in_new, size: 18),
                  SizedBox(width: 8),
                  Text('View'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'download',
              child: Row(
                children: [
                  Icon(Icons.download, size: 18),
                  SizedBox(width: 8),
                  Text('Download'),
                ],
              ),
            ),
            if (document.tenantId != null)
              const PopupMenuItem(
                value: 'send',
                child: Row(
                  children: [
                    Icon(Icons.send, size: 18),
                    SizedBox(width: 8),
                    Text('Send to Tenant'),
                  ],
                ),
              ),
            const PopupMenuItem(
              value: 'delete',
              child: Row(
                children: [
                  Icon(Icons.delete, color: AppTheme.error, size: 18),
                  SizedBox(width: 8),
                  Text('Delete', style: TextStyle(color: AppTheme.error)),
                ],
              ),
            ),
          ],
          onSelected: (value) {
            switch (value) {
              case 'view':
                _viewDocument(document);
                break;
              case 'download':
                _downloadDocument(document);
                break;
              case 'send':
                _sendDocumentToTenant(document);
                break;
              case 'delete':
                _deleteDocument(document);
                break;
            }
          },
        ),
        onTap: () => _viewDocument(document),
      ),
    );
  }

  IconData _getDocumentIcon(DocumentType type) {
    switch (type) {
      case DocumentType.contract:
        return Icons.description;
      case DocumentType.invoice:
        return Icons.receipt;
      case DocumentType.receipt:
        return Icons.receipt_long;
      case DocumentType.notice:
        return Icons.notifications;
      case DocumentType.lien:
        return Icons.gavel;
      case DocumentType.other:
        return Icons.insert_drive_file;
    }
  }

  Color _getDocumentColor(DocumentType type) {
    switch (type) {
      case DocumentType.contract:
        return AppTheme.primaryBlue;
      case DocumentType.invoice:
        return AppTheme.warning;
      case DocumentType.receipt:
        return AppTheme.success;
      case DocumentType.notice:
        return AppTheme.error;
      case DocumentType.lien:
        return Colors.purple;
      case DocumentType.other:
        return AppTheme.textTertiary;
    }
  }

  String _getTypeLabel(DocumentType type) {
    switch (type) {
      case DocumentType.contract:
        return 'Contract';
      case DocumentType.invoice:
        return 'Invoice';
      case DocumentType.receipt:
        return 'Receipt';
      case DocumentType.notice:
        return 'Notice';
      case DocumentType.lien:
        return 'Lien';
      case DocumentType.other:
        return 'Other';
    }
  }

  String _getCategoryLabel(DocumentCategory category) {
    switch (category) {
      case DocumentCategory.tenant:
        return 'Tenant';
      case DocumentCategory.facility:
        return 'Facility';
      case DocumentCategory.unit:
        return 'Unit';
      case DocumentCategory.contract:
        return 'Contract';
      case DocumentCategory.payment:
        return 'Payment';
      case DocumentCategory.legal:
        return 'Legal';
      case DocumentCategory.other:
        return 'Other';
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  void _viewDocument(DocumentAttachment document) async {
    try {
      final uri = Uri.parse(document.fileUrl);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open document')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error opening document: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  void _downloadDocument(DocumentAttachment document) {
    _viewDocument(document); // For now, same as view
  }

  Future<void> _sendDocumentToTenant(DocumentAttachment document) async {
    // Check if document has tenant ID
    if (document.tenantId == null || document.tenantId!.isEmpty) {
      // Show dialog to select tenant if not linked
      final tenantId = await _showSelectTenantDialog(document.facilityId);
      if (tenantId == null) return;
      
      // Update document with tenant ID (optional - could be done via service)
      // For now, we'll just use it for sending
      await _sendDocumentEmail(document, tenantId);
    } else {
      await _sendDocumentEmail(document, document.tenantId!);
    }
  }

  Future<String?> _showSelectTenantDialog(String facilityId) async {
    // Get tenants for facility
    final tenantsAsync = ref.read(facilityTenantsProvider(facilityId));
    final tenants = await tenantsAsync.when(
      data: (list) => list,
      loading: () => <TenantModel>[],
      error: (_, __) => <TenantModel>[],
    );

    if (tenants.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No tenants found for this facility')),
        );
      }
      return null;
    }

    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Tenant'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: tenants.length,
            itemBuilder: (context, index) {
              final tenant = tenants[index];
              return ListTile(
                title: Text(tenant.name),
                subtitle: Text(tenant.email.isNotEmpty ? tenant.email : tenant.phone),
                onTap: () => Navigator.of(context).pop(tenant.id),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Future<void> _sendDocumentEmail(DocumentAttachment document, String tenantId) async {
    try {
      // Get tenant information
      final tenant = await TenantService.getTenantById(document.facilityId, tenantId);
      if (tenant == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Tenant not found')),
          );
        }
        return;
      }

      if (tenant.email.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Tenant does not have an email address')),
          );
        }
        return;
      }

      // Get facility information
      final facility = await FacilityService.getFacility(document.facilityId);
      final facilityName = facility?.name ?? 'Storage Facility';

      // Prepare email content
      final subject = 'Document: ${document.fileName}';
      final htmlBody = '''
<html>
<body>
  <p>Dear ${tenant.name},</p>
  <p>Please find attached the following document from ${facilityName}:</p>
  <p><strong>${document.fileName}</strong></p>
  ${document.description != null && document.description!.isNotEmpty ? '<p>${document.description}</p>' : ''}
  <p><a href="${document.fileUrl}" style="background-color: #4CAF50; color: white; padding: 10px 20px; text-decoration: none; border-radius: 5px; display: inline-block;">View Document</a></p>
  <p>If you have any questions, please contact us.</p>
  <p>Best regards,<br>${facilityName}</p>
</body>
</html>
''';

      final textBody = '''
Dear ${tenant.name},

Please find the following document from ${facilityName}:

${document.fileName}
${document.description != null && document.description!.isNotEmpty ? '\n${document.description}\n' : ''}

View document: ${document.fileUrl}

If you have any questions, please contact us.

Best regards,
${facilityName}
''';

      // Send email
      final result = await EmailService.sendEmail(
        to: tenant.email,
        subject: subject,
        html: htmlBody,
        text: textBody,
        facilityId: document.facilityId,
        tenantId: tenantId,
        relatedEntityType: 'document',
        relatedEntityId: document.id,
      );

      if (mounted) {
        if (result.success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Document sent to ${tenant.name}'),
              backgroundColor: AppTheme.success,
            ),
          );
        } else {
          showStaffEmailFailureSnackBar(context, result);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error sending document: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _deleteDocument(DocumentAttachment document) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Document'),
        content: Text('Are you sure you want to delete "${document.fileName}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await DocumentService.deleteDocument(
          facilityId: document.facilityId,
          documentId: document.id,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Document deleted'),
              backgroundColor: AppTheme.success,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error deleting document: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }

  void _showUploadDialog() {
    if (_selectedFacilityId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a facility first')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) => _UploadDocumentDialog(
        facilityId: _selectedFacilityId!,
        tenantId: widget.tenantId,
        onUploaded: () {
          Navigator.of(context).pop();
        },
      ),
    );
  }
}

/// Dialog for uploading documents
class _UploadDocumentDialog extends StatefulWidget {
  final String facilityId;
  final String? tenantId;
  final VoidCallback onUploaded;

  const _UploadDocumentDialog({
    required this.facilityId,
    this.tenantId,
    required this.onUploaded,
  });

  @override
  State<_UploadDocumentDialog> createState() => _UploadDocumentDialogState();
}

class _UploadDocumentDialogState extends State<_UploadDocumentDialog> {
  DocumentType? _selectedType;
  DocumentCategory? _selectedCategory;
  final _descriptionController = TextEditingController();
  bool _isUploading = false;

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _uploadDocument() async {
    if (_selectedType == null || _selectedCategory == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select document type and category')),
      );
      return;
    }

    setState(() {
      _isUploading = true;
    });

    try {
      await DocumentService.uploadDocumentFromPicker(
        facilityId: widget.facilityId,
        documentType: _selectedType!,
        category: _selectedCategory!,
        tenantId: widget.tenantId,
        description: _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Document uploaded successfully'),
            backgroundColor: AppTheme.success,
          ),
        );
        widget.onUploaded();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error uploading document: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
        setState(() {
          _isUploading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Upload Document'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<DocumentType>(
              value: _selectedType,
              decoration: const InputDecoration(
                labelText: 'Document Type *',
                border: OutlineInputBorder(),
              ),
              items: DocumentType.values.map((type) {
                return DropdownMenuItem(
                  value: type,
                  child: Text(_getTypeLabel(type)),
                );
              }).toList(),
              onChanged: (value) {
                setState(() {
                  _selectedType = value;
                });
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<DocumentCategory>(
              value: _selectedCategory,
              decoration: const InputDecoration(
                labelText: 'Category *',
                border: OutlineInputBorder(),
              ),
              items: DocumentCategory.values.map((cat) {
                return DropdownMenuItem(
                  value: cat,
                  child: Text(_getCategoryLabel(cat)),
                );
              }).toList(),
              onChanged: (value) {
                setState(() {
                  _selectedCategory = value;
                });
              },
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isUploading ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isUploading ? null : _uploadDocument,
          child: _isUploading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Upload'),
        ),
      ],
    );
  }

  String _getTypeLabel(DocumentType type) {
    switch (type) {
      case DocumentType.contract:
        return 'Contract';
      case DocumentType.invoice:
        return 'Invoice';
      case DocumentType.receipt:
        return 'Receipt';
      case DocumentType.notice:
        return 'Notice';
      case DocumentType.lien:
        return 'Lien';
      case DocumentType.other:
        return 'Other';
    }
  }

  String _getCategoryLabel(DocumentCategory category) {
    switch (category) {
      case DocumentCategory.tenant:
        return 'Tenant';
      case DocumentCategory.facility:
        return 'Facility';
      case DocumentCategory.unit:
        return 'Unit';
      case DocumentCategory.contract:
        return 'Contract';
      case DocumentCategory.payment:
        return 'Payment';
      case DocumentCategory.legal:
        return 'Legal';
      case DocumentCategory.other:
        return 'Other';
    }
  }
}

