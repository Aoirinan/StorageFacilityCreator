import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/sms_template_model.dart';
import 'package:sfcapp/services/template_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/widgets/modern_page_wrapper.dart';

/// Screen for managing SMS templates
class SMSTemplateManagementScreen extends StatefulWidget {
  final String? facilityId;

  const SMSTemplateManagementScreen({
    super.key,
    this.facilityId,
  });

  @override
  State<SMSTemplateManagementScreen> createState() => _SMSTemplateManagementScreenState();
}

class _SMSTemplateManagementScreenState extends State<SMSTemplateManagementScreen> {
  List<SMSTemplateModel> _templates = [];
  bool _isLoading = true;
  String? _selectedCategory;
  final List<String> _categories = ['all', 'payment', 'reminder', 'welcome', 'receipt', 'general'];

  @override
  void initState() {
    super.initState();
    _selectedCategory = 'all';
    _loadTemplates();
  }

  Future<void> _loadTemplates() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final templates = await TemplateService.getSMSTemplates(widget.facilityId);
      setState(() {
        _templates = templates;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading templates: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  List<SMSTemplateModel> get _filteredTemplates {
    if (_selectedCategory == 'all') {
      return _templates;
    }
    return _templates.where((t) => t.category == _selectedCategory).toList();
  }

  @override
  Widget build(BuildContext context) {
    final currentRoute = GoRouter.of(context).routeInformationProvider.value.location ?? '/templates/sms';
    
    return ModernPageWrapper(
      currentRoute: currentRoute,
      title: 'SMS Templates',
      actions: [
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: () => _showCreateTemplateDialog(),
          tooltip: 'Create Template',
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _loadTemplates,
          tooltip: 'Refresh',
        ),
      ],
      child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Category Filter
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: SegmentedButton<String>(
                    segments: _categories.map((cat) {
                      return ButtonSegment<String>(
                        value: cat,
                        label: Text(cat == 'all' ? 'All' : cat.toUpperCase()),
                      );
                    }).toList(),
                    selected: {_selectedCategory!},
                    onSelectionChanged: (Set<String> selected) {
                      setState(() {
                        _selectedCategory = selected.first;
                      });
                    },
                  ),
                ),
                const Divider(),
                // Template List
                Expanded(
                  child: _filteredTemplates.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.sms_outlined, size: 64, color: AppTheme.textTertiary),
                              const SizedBox(height: 16),
                              Text(
                                'No templates found',
                                style: TextStyle(color: AppTheme.textTertiary),
                              ),
                              const SizedBox(height: 8),
                              ElevatedButton.icon(
                                onPressed: () => _showCreateTemplateDialog(),
                                icon: const Icon(Icons.add),
                                label: const Text('Create Template'),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: _filteredTemplates.length,
                          itemBuilder: (context, index) {
                            final template = _filteredTemplates[index];
                            return _buildTemplateCard(template);
                          },
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildTemplateCard(SMSTemplateModel template) {
    final charCount = template.characterCount;
    final isOverLimit = charCount > 160;
    
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppTheme.success.withOpacity(0.1),
          child: Icon(Icons.sms, color: AppTheme.success),
        ),
        title: Text(
          template.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Row(
              children: [
                Chip(
                  label: Text(template.category.toUpperCase()),
                  labelStyle: const TextStyle(fontSize: 10),
                  padding: EdgeInsets.zero,
                ),
                if (template.isDefault) ...[
                  const SizedBox(width: 4),
                  Chip(
                    label: const Text('DEFAULT'),
                    labelStyle: const TextStyle(fontSize: 10),
                    backgroundColor: AppTheme.success.withOpacity(0.2),
                    padding: EdgeInsets.zero,
                  ),
                ],
                if (template.facilityId == null) ...[
                  const SizedBox(width: 4),
                  Chip(
                    label: const Text('GLOBAL'),
                    labelStyle: const TextStyle(fontSize: 10),
                    backgroundColor: AppTheme.primaryBlue.withOpacity(0.2),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ],
            ),
            if (template.description != null) ...[
              const SizedBox(height: 4),
              Text(
                template.description!,
                style: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 4),
            Text(
              template.message,
              style: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  '$charCount characters',
                  style: TextStyle(
                    color: isOverLimit ? AppTheme.error : AppTheme.textTertiary,
                    fontSize: 11,
                    fontWeight: isOverLimit ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                if (isOverLimit) ...[
                  const SizedBox(width: 8),
                  Text(
                    '(Multiple SMS)',
                    style: TextStyle(
                      color: AppTheme.error,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          itemBuilder: (context) => <PopupMenuEntry<String>>[
            const PopupMenuItem(
              value: 'edit',
              child: Row(
                children: [
                  Icon(Icons.edit, size: 18),
                  SizedBox(width: 8),
                  Text('Edit'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'preview',
              child: Row(
                children: [
                  Icon(Icons.preview, size: 18),
                  SizedBox(width: 8),
                  Text('Preview'),
                ],
              ),
            ),
            if (!template.isDefault)
              const PopupMenuItem(
                value: 'setDefault',
                child: Row(
                  children: [
                    Icon(Icons.star, size: 18),
                    SizedBox(width: 8),
                    Text('Set as Default'),
                  ],
                ),
              ),
            const PopupMenuDivider(),
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
              case 'edit':
                _showEditTemplateDialog(template);
                break;
              case 'preview':
                _showPreviewDialog(template);
                break;
              case 'setDefault':
                _setAsDefault(template);
                break;
              case 'delete':
                _deleteTemplate(template);
                break;
            }
          },
        ),
        onTap: () => _showEditTemplateDialog(template),
      ),
    );
  }

  void _showCreateTemplateDialog() {
    _showTemplateDialog();
  }

  void _showEditTemplateDialog(SMSTemplateModel template) {
    _showTemplateDialog(template: template);
  }

  void _showTemplateDialog({SMSTemplateModel? template}) {
    // This would open a full-screen template editor
    // For now, show a simple dialog
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(template == null ? 'Create SMS Template' : 'Edit SMS Template'),
        content: const Text('SMS template editor will be implemented here.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showPreviewDialog(SMSTemplateModel template) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Preview: ${template.name}'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(template.message),
              ),
              const SizedBox(height: 16),
              Text(
                '${template.characterCount} characters',
                style: TextStyle(
                  color: template.requiresMultipleSMS ? AppTheme.error : AppTheme.textTertiary,
                  fontWeight: template.requiresMultipleSMS ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              if (template.requiresMultipleSMS)
                Text(
                  'This message will be sent as multiple SMS',
                  style: TextStyle(color: AppTheme.error, fontSize: 12),
                ),
              if (template.variables.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Variables:', style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: template.variables.map((v) {
                    return Chip(
                      label: Text('{$v}'),
                      labelStyle: const TextStyle(fontSize: 11),
                    );
                  }).toList(),
                ),
              ],
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

  Future<void> _setAsDefault(SMSTemplateModel template) async {
    try {
      // Unset other defaults in same category
      final templates = await TemplateService.getSMSTemplates(widget.facilityId);
      for (final t in templates) {
        if (t.category == template.category && t.isDefault && t.id != template.id) {
          await TemplateService.saveSMSTemplate(
            t.copyWith(isDefault: false),
            widget.facilityId,
          );
        }
      }

      // Set this as default
      await TemplateService.saveSMSTemplate(
        template.copyWith(isDefault: true),
        widget.facilityId,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Template set as default'),
            backgroundColor: AppTheme.success,
          ),
        );
        _loadTemplates();
      }
    } catch (e) {
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

  Future<void> _deleteTemplate(SMSTemplateModel template) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Template'),
        content: Text('Are you sure you want to delete "${template.name}"?'),
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
        await TemplateService.deleteSMSTemplate(template.id, widget.facilityId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Template deleted'),
              backgroundColor: AppTheme.success,
            ),
          );
          _loadTemplates();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error deleting template: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }
}

