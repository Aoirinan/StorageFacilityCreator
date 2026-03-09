import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import '../models/contract_template_model.dart';
import '../models/contract_model.dart';
import '../providers/contract_provider.dart';
import '../services/contract_service.dart';
import '../theme/app_theme.dart';
import '../widgets/signature_field_configurator.dart';
import '../router/app_route.dart';

/// Full-page screen for creating a contract template (replaces the previous dialog).
class CreateContractTemplateScreen extends ConsumerStatefulWidget {
  final String facilityId;

  const CreateContractTemplateScreen({super.key, required this.facilityId});

  @override
  ConsumerState<CreateContractTemplateScreen> createState() =>
      _CreateContractTemplateScreenState();
}

class _CreateContractTemplateScreenState
    extends ConsumerState<CreateContractTemplateScreen> {
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  ContractType _selectedType = ContractType.storage;
  PlatformFile? _selectedFile;
  bool _isUploading = false;
  List<SignaturePlaceholder> _configuredPlaceholders = [];

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  Future<void> _createTemplate() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a template name')),
      );
      return;
    }
    setState(() => _isUploading = true);
    try {
      String? fileUrl;
      if (_selectedFile != null && _selectedFile!.bytes != null) {
        final tempId = 'template_${DateTime.now().millisecondsSinceEpoch}';
        fileUrl = await ContractService.uploadContractFile(
          facilityId: widget.facilityId,
          contractId: tempId,
          fileData: Uint8List.fromList(_selectedFile!.bytes!),
          fileName: _selectedFile!.name,
          skipFirestoreUpdate: true,
        );
      }
      await ContractService.createContractTemplate(
        facilityId: widget.facilityId,
        name: name,
        description: _descController.text.trim().isNotEmpty
            ? _descController.text.trim()
            : 'Custom template',
        content: '',
        type: _selectedType,
        fileUrl: fileUrl,
        signaturePlaceholders: _configuredPlaceholders.isNotEmpty
            ? _configuredPlaceholders
            : null,
      );
      if (!mounted) return;
      ref.invalidate(contractTemplatesProvider(widget.facilityId));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            fileUrl != null
                ? 'Template "$name" created with PDF and ${_configuredPlaceholders.length} signature fields.'
                : 'Template "$name" created.',
          ),
          backgroundColor: AppTheme.success,
        ),
      );
      context.pop();
    } catch (e) {
      setState(() => _isUploading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Contract Template'),
        backgroundColor: AppTheme.primaryBlueDark,
        foregroundColor: AppTheme.textOnDark,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildSection(
                  title: 'Template info',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Template name *',
                          border: OutlineInputBorder(),
                          hintText: 'e.g. Self-Storage Rental Agreement',
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _descController,
                        decoration: const InputDecoration(
                          labelText: 'Description',
                          border: OutlineInputBorder(),
                          hintText: 'Short description for this template',
                        ),
                        maxLines: 2,
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<ContractType>(
                        value: _selectedType,
                        decoration: const InputDecoration(
                          labelText: 'Type',
                          border: OutlineInputBorder(),
                        ),
                        items: ContractType.values
                            .map((t) => DropdownMenuItem(
                                  value: t,
                                  child: Text(t.name),
                                ))
                            .toList(),
                        onChanged: (v) {
                          if (v != null) setState(() => _selectedType = v);
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                _buildSection(
                  title: 'Contract PDF',
                  subtitle:
                      'Upload once. All contracts from this template will use this PDF.',
                  child: _selectedFile == null
                      ? OutlinedButton.icon(
                          onPressed: () async {
                            final result = await FilePicker.platform.pickFiles(
                              type: FileType.custom,
                              allowedExtensions: ['pdf'],
                              withData: true,
                            );
                            if (result != null &&
                                result.files.isNotEmpty &&
                                result.files.single.bytes != null &&
                                result.files.single.bytes!.isNotEmpty) {
                              setState(() =>
                                  _selectedFile = result.files.single);
                            }
                          },
                          icon: const Icon(Icons.upload_file),
                          label: const Text('Choose PDF file'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 16),
                          ),
                        )
                      : Row(
                          children: [
                            Icon(Icons.check_circle,
                                color: AppTheme.success, size: 24),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _selectedFile!.name,
                                style: TextStyle(
                                  color: AppTheme.success,
                                  fontWeight: FontWeight.w500,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () => setState(() {
                                _selectedFile = null;
                                _configuredPlaceholders = [];
                              }),
                              tooltip: 'Remove PDF',
                            ),
                          ],
                        ),
                ),
                if (_selectedFile != null &&
                    _selectedFile!.bytes != null &&
                    _selectedFile!.bytes!.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  _buildSection(
                    title: 'Signature fields',
                    subtitle:
                        'Add fields (e.g. signature, date, unit number) and tap on the PDF to place each one.',
                    child: SignatureFieldConfigurator(
                      pdfBytes:
                          Uint8List.fromList(_selectedFile!.bytes!),
                      initialPlaceholders: _configuredPlaceholders,
                      onPlaceholdersChanged: (p) {
                        setState(() => _configuredPlaceholders = p);
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 32),
                SizedBox(
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: _isUploading ? null : _createTemplate,
                    icon: _isUploading
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save),
                    label: Text(
                        _isUploading ? 'Creating…' : 'Create template'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryBlueDark,
                      foregroundColor: AppTheme.textOnDark,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSection({
    required String title,
    String? subtitle,
    required Widget child,
  }) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Theme.of(context).dividerColor),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: AppTheme.primaryBlueDark,
                  ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}
