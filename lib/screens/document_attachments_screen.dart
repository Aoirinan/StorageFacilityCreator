import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/document_attachment_model.dart';
import '../services/document_service.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';

/// Provider for documents stream
final documentsProvider = StreamProvider.family<List<DocumentAttachment>, Map<String, String?>>((ref, params) {
  final facilityId = params['facilityId']!;
  final tenantId = params['tenantId'];
  
  if (tenantId != null && tenantId.isNotEmpty) {
    return DocumentService.getDocumentsForTenantStream(
      facilityId: facilityId,
      tenantId: tenantId,
    );
  } else {
    return DocumentService.getDocumentsForFacilityStream(facilityId);
  }
});

class DocumentAttachmentsScreen extends ConsumerStatefulWidget {
  final String facilityId;
  final String? tenantId;
  final String? unitId;
  final String? contractId;
  final String? paymentId;
  final String? invoiceId;
  final String? lienId;

  const DocumentAttachmentsScreen({
    super.key,
    required this.facilityId,
    this.tenantId,
    this.unitId,
    this.contractId,
    this.paymentId,
    this.invoiceId,
    this.lienId,
  });

  @override
  ConsumerState<DocumentAttachmentsScreen> createState() => _DocumentAttachmentsScreenState();
}

class _DocumentAttachmentsScreenState extends ConsumerState<DocumentAttachmentsScreen> {
  DocumentType? _typeFilter;
  DocumentCategory? _categoryFilter;

  @override
  Widget build(BuildContext context) {
    return ModernPageWrapper(
      currentRoute: '/documents',
      title: 'Document Attachments',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      actions: [
        IconButton(
          icon: const Icon(Icons.upload_file),
          onPressed: () => _showUploadDialog(),
          tooltip: 'Upload Document',
        ),
      ],
      child: Column(
        children: [
          _buildFilters(),
          Expanded(
            child: _buildDocumentsList(),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: AppTheme.backgroundLight,
        border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
      ),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<DocumentType?>(
              value: _typeFilter,
              decoration: InputDecoration(
                labelText: 'Document Type',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('All Types')),
                ...DocumentType.values.map((type) {
                  return DropdownMenuItem(
                    value: type,
                    child: Text(_getTypeLabel(type)),
                  );
                }),
              ],
              onChanged: (value) {
                setState(() {
                  _typeFilter = value;
                });
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<DocumentCategory?>(
              value: _categoryFilter,
              decoration: InputDecoration(
                labelText: 'Category',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('All Categories')),
                ...DocumentCategory.values.map((category) {
                  return DropdownMenuItem(
                    value: category,
                    child: Text(_getCategoryLabel(category)),
                  );
                }),
              ],
              onChanged: (value) {
                setState(() {
                  _categoryFilter = value;
                });
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDocumentsList() {
    final docsAsync = ref.watch(documentsProvider({
      'facilityId': widget.facilityId,
      'tenantId': widget.tenantId,
    }));

    return docsAsync.when(
      data: (documents) {
        // Apply filters
        var filteredDocs = documents;
        
        if (_typeFilter != null) {
          filteredDocs = filteredDocs.where((doc) => doc.documentType == _typeFilter).toList();
        }
        
        if (_categoryFilter != null) {
          filteredDocs = filteredDocs.where((doc) => doc.category == _categoryFilter).toList();
        }

        if (filteredDocs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.description, size: 64, color: AppTheme.textTertiary),
                const SizedBox(height: 16),
                Text(
                  'No documents found',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: () => _showUploadDialog(),
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Upload First Document'),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16.0),
          itemCount: filteredDocs.length,
          itemBuilder: (context, index) {
            final doc = filteredDocs[index];
            return _buildDocumentCard(doc);
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: AppTheme.error),
            const SizedBox(height: 16),
            Text(
              'Error loading documents',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: AppTheme.error,
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => ref.invalidate(documentsProvider({
                'facilityId': widget.facilityId,
                'tenantId': widget.tenantId,
              })),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDocumentCard(DocumentAttachment doc) {
    final icon = _getDocumentIcon(doc);
    final color = _getDocumentColor(doc);

    return Card(
      margin: const EdgeInsets.only(bottom: 12.0),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withOpacity(0.1),
          child: Icon(icon, color: color),
        ),
        title: Text(
          doc.fileName,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${doc.documentTypeDisplayName} • ${doc.categoryDisplayName}'),
            if (doc.description != null && doc.description!.isNotEmpty)
              Text(
                doc.description!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            Text(
              '${doc.formattedFileSize} • ${DateFormat('MMM d, y • h:mm a').format(doc.uploadedAt)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppTheme.textSecondary,
              ),
            ),
            if (doc.isExpired)
              Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.error.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Expired',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.error,
                    fontSize: 10,
                  ),
                ),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.download),
              onPressed: () => _downloadDocument(doc),
              tooltip: 'Download',
            ),
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () => _confirmDelete(doc),
              tooltip: 'Delete',
              color: AppTheme.error,
            ),
          ],
        ),
        onTap: () => _viewDocument(doc),
      ),
    );
  }

  IconData _getDocumentIcon(DocumentAttachment doc) {
    if (doc.isPdf) return Icons.picture_as_pdf;
    if (doc.isImage) return Icons.image;
    return Icons.description;
  }

  Color _getDocumentColor(DocumentAttachment doc) {
    if (doc.isPdf) return AppTheme.error;
    if (doc.isImage) return AppTheme.success;
    return AppTheme.primaryBlue;
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

  void _showUploadDialog() {
    showDialog(
      context: context,
      builder: (context) => _UploadDocumentDialog(
        facilityId: widget.facilityId,
        tenantId: widget.tenantId,
        unitId: widget.unitId,
        contractId: widget.contractId,
        paymentId: widget.paymentId,
        invoiceId: widget.invoiceId,
        lienId: widget.lienId,
        onUploaded: () {
          // Refresh will happen automatically via stream
          Navigator.pop(context);
        },
      ),
    );
  }

  Future<void> _viewDocument(DocumentAttachment doc) async {
    final uri = Uri.parse(doc.fileUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open document: ${doc.fileName}'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _downloadDocument(DocumentAttachment doc) async {
    final uri = Uri.parse(doc.fileUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not download document: ${doc.fileName}'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  void _confirmDelete(DocumentAttachment doc) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Document'),
        content: Text('Are you sure you want to delete "${doc.fileName}"? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await DocumentService.deleteDocument(
                  facilityId: widget.facilityId,
                  documentId: doc.id,
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

class _UploadDocumentDialog extends StatefulWidget {
  final String facilityId;
  final String? tenantId;
  final String? unitId;
  final String? contractId;
  final String? paymentId;
  final String? invoiceId;
  final String? lienId;
  final VoidCallback onUploaded;

  const _UploadDocumentDialog({
    required this.facilityId,
    this.tenantId,
    this.unitId,
    this.contractId,
    this.paymentId,
    this.invoiceId,
    this.lienId,
    required this.onUploaded,
  });

  @override
  State<_UploadDocumentDialog> createState() => _UploadDocumentDialogState();
}

class _UploadDocumentDialogState extends State<_UploadDocumentDialog> {
  DocumentType _selectedType = DocumentType.other;
  DocumentCategory _selectedCategory = DocumentCategory.other;
  String? _description;
  bool _isUploading = false;

  Future<void> _uploadDocument() async {
    setState(() {
      _isUploading = true;
    });

    try {
      await DocumentService.uploadDocumentFromPicker(
        facilityId: widget.facilityId,
        documentType: _selectedType,
        category: _selectedCategory,
        tenantId: widget.tenantId,
        unitId: widget.unitId,
        contractId: widget.contractId,
        paymentId: widget.paymentId,
        invoiceId: widget.invoiceId,
        lienId: widget.lienId,
        description: _description?.trim().isEmpty == true ? null : _description?.trim(),
      );

      if (mounted) {
        widget.onUploaded();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Document uploaded successfully'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error uploading document: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: 500,
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Upload Document',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 24),
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
                if (value != null) {
                  setState(() {
                    _selectedType = value;
                  });
                }
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<DocumentCategory>(
              value: _selectedCategory,
              decoration: const InputDecoration(
                labelText: 'Category *',
                border: OutlineInputBorder(),
              ),
              items: DocumentCategory.values.map((category) {
                return DropdownMenuItem(
                  value: category,
                  child: Text(_getCategoryLabel(category)),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _selectedCategory = value;
                  });
                }
              },
            ),
            const SizedBox(height: 16),
            TextField(
              decoration: const InputDecoration(
                labelText: 'Description (Optional)',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
              onChanged: (value) {
                setState(() {
                  _description = value;
                });
              },
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _isUploading ? null : _uploadDocument,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryBlue,
                    foregroundColor: Colors.white,
                  ),
                  child: _isUploading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Upload'),
                ),
              ],
            ),
          ],
        ),
      ),
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

