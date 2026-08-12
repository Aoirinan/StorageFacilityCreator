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

/// Full-page screen for editing an existing contract template.
/// Allows renaming, changing description/type, replacing the PDF,
/// and adding/moving/removing signature fields.
class EditContractTemplateScreen extends ConsumerStatefulWidget {
  final ContractTemplateModel template;

  const EditContractTemplateScreen({super.key, required this.template});

  @override
  ConsumerState<EditContractTemplateScreen> createState() =>
      _EditContractTemplateScreenState();
}

class _EditContractTemplateScreenState
    extends ConsumerState<EditContractTemplateScreen> {
  late final TextEditingController _nameController;
  late final TextEditingController _descController;
  late ContractType _selectedType;

  // PDF state: either keep existing URL or replace with new bytes
  PlatformFile? _replacementFile; // non-null when user picks a new PDF
  bool _keepExistingPdf = true;   // false if user removes without replacing

  late List<SignaturePlaceholder> _placeholders;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.template.name);
    _descController = TextEditingController(text: widget.template.description);
    _selectedType = widget.template.type;
    _placeholders = List.of(widget.template.signaturePlaceholders);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  // The URL to show in the configurator (proxy-safe for web)
  String? get _activePdfUrl {
    if (_replacementFile != null) return null; // using bytes instead
    if (!_keepExistingPdf) return null;
    final url = widget.template.fileUrl;
    if (url == null || url.isEmpty) return null;
    return ContractService.getPdfFetchUrl(url);
  }

  Uint8List? get _activePdfBytes {
    if (_replacementFile?.bytes != null) {
      return Uint8List.fromList(_replacementFile!.bytes!);
    }
    return null;
  }

  bool get _hasPdf =>
      _activePdfUrl != null || _activePdfBytes != null;

  Future<void> _pickReplacementPdf() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      withData: true,
    );
    if (result != null &&
        result.files.isNotEmpty &&
        result.files.single.bytes != null &&
        result.files.single.bytes!.isNotEmpty) {
      setState(() {
        _replacementFile = result.files.single;
        _keepExistingPdf = false;
        _placeholders = []; // reset placements when PDF changes
      });
    }
  }

  Future<void> _saveTemplate() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a template name')),
      );
      return;
    }
    setState(() => _isSaving = true);
    try {
      String? newFileUrl;

      // Upload replacement PDF if one was chosen
      if (_replacementFile != null && _replacementFile!.bytes != null) {
        final tempId = 'template_${DateTime.now().millisecondsSinceEpoch}';
        newFileUrl = await ContractService.uploadContractFile(
          facilityId: widget.template.facilityId,
          contractId: tempId,
          fileData: Uint8List.fromList(_replacementFile!.bytes!),
          fileName: _replacementFile!.name,
          skipFirestoreUpdate: true,
        );
      }

      await ContractService.updateContractTemplate(
        facilityId: widget.template.facilityId,
        templateId: widget.template.id,
        name: name,
        description: _descController.text.trim().isNotEmpty
            ? _descController.text.trim()
            : 'Custom template',
        type: _selectedType,
        signaturePlaceholders: _placeholders,
        fileUrl: newFileUrl,
      );

      if (!mounted) return;
      ref.invalidate(contractTemplatesProvider(widget.template.facilityId));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Template updated.'),
          backgroundColor: AppTheme.success,
        ),
      );
      context.pop();
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: cs.surface,
        foregroundColor: cs.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 1,
        title: Text(
          'Edit Template',
          style: theme.textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: cs.outlineVariant),
        ),
        actions: [
          if (_isSaving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                ),
              ),
            )
          else
            TextButton.icon(
              onPressed: _saveTemplate,
              icon: const Icon(Icons.save, color: Colors.white),
              label: const Text('Save',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Template Info ──────────────────────────────────────
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
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _descController,
                        decoration: const InputDecoration(
                          labelText: 'Description',
                          border: OutlineInputBorder(),
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

                // ── Contract PDF ───────────────────────────────────────
                _buildSection(
                  title: 'Contract PDF',
                  subtitle: 'Replace the PDF if needed. Changing the PDF resets field placements.',
                  child: _buildPdfSection(),
                ),

                // ── Signature Fields ───────────────────────────────────
                if (_hasPdf) ...[
                  const SizedBox(height: 24),
                  _buildSection(
                    title: 'Signature fields',
                    subtitle:
                        'Add, move, or remove fields. Tap "Place" on any field to reposition it on the PDF.',
                    child: SignatureFieldConfigurator(
                      pdfBytes: _activePdfBytes,
                      pdfUrl: _activePdfUrl,
                      initialPlaceholders: _placeholders,
                      onPlaceholdersChanged: (p) =>
                          setState(() => _placeholders = p),
                    ),
                  ),
                ],

                const SizedBox(height: 32),
                SizedBox(
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: _isSaving ? null : _saveTemplate,
                    icon: _isSaving
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.save),
                    label: Text(_isSaving ? 'Saving…' : 'Save changes'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryBlueDark,
                      foregroundColor: AppTheme.textOnDark,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
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

  Widget _buildPdfSection() {
    // Replacement file chosen
    if (_replacementFile != null) {
      return Row(
        children: [
          Icon(Icons.check_circle, color: AppTheme.success, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _replacementFile!.name,
              style: TextStyle(
                  color: AppTheme.success, fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Remove new PDF (revert to original)',
            onPressed: () => setState(() {
              _replacementFile = null;
              _keepExistingPdf = widget.template.fileUrl != null;
              _placeholders = List.of(widget.template.signaturePlaceholders);
            }),
          ),
        ],
      );
    }

    // Existing PDF kept
    if (_keepExistingPdf && widget.template.fileUrl != null) {
      return Row(
        children: [
          Icon(Icons.picture_as_pdf, color: AppTheme.primaryBlueDark, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Using existing PDF',
              style: TextStyle(
                  color: AppTheme.primaryBlueDark,
                  fontWeight: FontWeight.w500),
            ),
          ),
          TextButton.icon(
            onPressed: _pickReplacementPdf,
            icon: const Icon(Icons.swap_horiz, size: 18),
            label: const Text('Replace'),
          ),
        ],
      );
    }

    // No PDF
    return OutlinedButton.icon(
      onPressed: _pickReplacementPdf,
      icon: const Icon(Icons.upload_file),
      label: const Text('Choose PDF file'),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
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
