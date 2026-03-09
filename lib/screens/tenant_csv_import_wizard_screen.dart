import 'dart:convert';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';
import 'package:go_router/go_router.dart';
import '../services/tenant_service.dart';
import '../theme/app_theme.dart';
import '../router/app_route.dart';
import '../providers/tenant_provider.dart';

/// CSV Import Wizard with multiple steps:
/// 1. Upload CSV file
/// 2. Map columns to tenant fields
/// 3. Preview & validate data
/// 4. Handle duplicates
/// 5. Import & show results
class TenantCsvImportWizardScreen extends ConsumerStatefulWidget {
  final String facilityId;

  const TenantCsvImportWizardScreen({
    super.key,
    required this.facilityId,
  });

  @override
  ConsumerState<TenantCsvImportWizardScreen> createState() => _TenantCsvImportWizardScreenState();
}

class _TenantCsvImportWizardScreenState extends ConsumerState<TenantCsvImportWizardScreen> {
  int _currentStep = 0;
  List<List<dynamic>>? _csvData;
  List<String>? _csvHeaders;
  Map<String, String> _columnMapping = {}; // Maps tenant field -> CSV column name
  List<Map<String, dynamic>> _parsedRows = []; // Parsed tenant data
  List<String> _validationErrors = [];
  List<int> _duplicateRowIndices = []; // Rows that are duplicates
  Map<int, String> _duplicateReasons = {}; // Why each row is a duplicate
  bool _skipDuplicates = true;
  int _successCount = 0;
  int _errorCount = 0;
  List<String> _importErrors = [];
  bool _isImporting = false;
  int _totalRowsToImport = 0;

  // Field definitions for mapping
  // Note: Only 'name' is truly required for import - other fields can be filled in later
  final List<Map<String, dynamic>> _tenantFields = [
    {'key': 'name', 'label': 'Full Name', 'required': true, 'synonyms': ['name', 'full name', 'tenant name', 'customer name', 'client name']},
    {'key': 'email', 'label': 'Email', 'required': false, 'synonyms': ['email', 'email address', 'e-mail', 'e mail']},
    {'key': 'phone', 'label': 'Phone', 'required': false, 'synonyms': ['phone', 'phone number', 'telephone', 'mobile', 'cell']},
    {'key': 'unitNumber', 'label': 'Unit Number', 'required': false, 'synonyms': ['unit', 'unit number', 'unit #', 'unit id', 'storage unit']},
    {'key': 'monthlyRate', 'label': 'Monthly Rate', 'required': false, 'synonyms': ['rate', 'monthly rate', 'rent', 'rental rate', 'price', 'monthly rent']},
    {'key': 'notes', 'label': 'Notes', 'required': false, 'synonyms': ['notes', 'note', 'comments', 'remarks', 'description']},
  ];

  @override
  void initState() {
    super.initState();
    _autoMapColumns();
  }

  void _autoMapColumns() {
    if (_csvHeaders == null) return;

    final mapping = <String, String>{};
    final usedColumns = <String>{};

    // Auto-map based on synonyms
    for (final field in _tenantFields) {
      final fieldKey = field['key'] as String;
      final synonyms = (field['synonyms'] as List).map((e) => e.toString().toLowerCase()).toList();

      for (final header in _csvHeaders!) {
        final headerLower = header.toLowerCase().trim();
        if (usedColumns.contains(header)) continue;

        if (synonyms.contains(headerLower)) {
          mapping[fieldKey] = header;
          usedColumns.add(header);
          break;
        }
      }
    }

    setState(() {
      _columnMapping = mapping;
    });
  }

  Future<void> _pickCsvFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) {
        return;
      }

      final file = result.files.first;
      if (file.bytes == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to read CSV file'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
        return;
      }

      // Parse CSV
      final csvString = utf8.decode(file.bytes!);
      final csvData = csv.decode(csvString);

      if (csvData.isEmpty || csvData.length < 2) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('CSV file is empty or invalid. Need at least a header row and one data row.'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
        return;
      }

      setState(() {
        _csvData = csvData;
        _csvHeaders = csvData[0].map((e) => e.toString().trim()).toList();
        _autoMapColumns();
        _currentStep = 1; // Move to mapping step
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error reading CSV: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  void _validateAndParse() {
    if (_csvData == null || _csvHeaders == null) return;

    final parsedRows = <Map<String, dynamic>>[];
    final errors = <String>[];
    final warnings = <String>[];

    // Only check that name is mapped (absolute minimum requirement)
    if (!_columnMapping.containsKey('name') || _columnMapping['name']!.isEmpty) {
      setState(() {
        _validationErrors = ['At least "Full Name" must be mapped to import tenants.'];
      });
      return;
    }

    // Parse each row
    for (int i = 1; i < _csvData!.length; i++) {
      final row = _csvData![i];
      final rowData = <String, dynamic>{};
      final rowWarnings = <String>[];

      for (final field in _tenantFields) {
        final fieldKey = field['key'] as String;
        final mappedColumn = _columnMapping[fieldKey];

        if (mappedColumn == null || mappedColumn.isEmpty) {
          // Field not mapped - use empty string (user can fill in later)
          if (fieldKey == 'monthlyRate') {
            rowData[fieldKey] = 0.0; // Default to 0 if not provided
          } else {
            rowData[fieldKey] = ''; // Empty string for other fields
          }
          continue;
        }

        final columnIndex = _csvHeaders!.indexOf(mappedColumn);
        if (columnIndex < 0 || columnIndex >= row.length) {
          // Column not found - use empty/default
          if (fieldKey == 'monthlyRate') {
            rowData[fieldKey] = 0.0;
          } else {
            rowData[fieldKey] = '';
          }
          continue;
        }

        final value = row[columnIndex].toString().trim();

        // Only validate name is not empty (required)
        if (fieldKey == 'name' && value.isEmpty) {
          errors.add('Row ${i + 1}: Name is required and cannot be empty');
          continue;
        }

        // Type conversion
        if (fieldKey == 'monthlyRate') {
          if (value.isEmpty) {
            rowData[fieldKey] = 0.0; // Default to 0 if empty
          } else {
            final rate = double.tryParse(value.replaceAll(RegExp(r'[^\d.]'), ''));
            if (rate == null || rate < 0) {
              rowWarnings.add('Row ${i + 1}: Invalid monthly rate "$value" - using 0.0');
              rowData[fieldKey] = 0.0;
            } else {
              rowData[fieldKey] = rate;
            }
          }
        } else {
          rowData[fieldKey] = value; // Can be empty - user can fill in later
        }
      }

      // Only add row if name is present
      if (rowData['name'] != null && (rowData['name'] as String).isNotEmpty) {
        rowData['_rowNumber'] = i + 1; // Store original row number
        parsedRows.add(rowData);
        if (rowWarnings.isNotEmpty) {
          warnings.addAll(rowWarnings);
        }
      } else {
        errors.add('Row ${i + 1}: Name is required');
      }
    }

    setState(() {
      _parsedRows = parsedRows;
      _validationErrors = errors;
      // Add warnings to validation errors for display (but don't block)
      if (warnings.isNotEmpty) {
        _validationErrors = [...errors, ...warnings.map((w) => '⚠️ $w')];
      }
    });

    // Check for duplicates
    _checkDuplicates();
  }

  Future<void> _checkDuplicates() async {
    if (_parsedRows.isEmpty) return;

    final duplicateIndices = <int>[];
    final duplicateReasons = <int, String>{};

    try {
      // Get existing tenants for facility
      final existingTenants = await TenantService.getTenantsForFacility(widget.facilityId);

      for (int i = 0; i < _parsedRows.length; i++) {
        final row = _parsedRows[i];
        final email = (row['email'] as String? ?? '').toLowerCase();
        final phone = (row['phone'] as String? ?? '').replaceAll(RegExp(r'[^\d]'), '');
        final unitNumber = (row['unitNumber'] as String? ?? '').trim();

        // Check for duplicate email
        final emailMatch = existingTenants.where((t) => t.email.toLowerCase() == email).firstOrNull;
        if (emailMatch != null) {
          duplicateIndices.add(i);
          duplicateReasons[i] = 'Email "${email}" already exists (Tenant: ${emailMatch.name})';
          continue;
        }

        // Check for duplicate phone
        final phoneMatch = existingTenants.where((t) => t.phone.replaceAll(RegExp(r'[^\d]'), '') == phone).firstOrNull;
        if (phoneMatch != null) {
          duplicateIndices.add(i);
          duplicateReasons[i] = 'Phone "${row['phone']}" already exists (Tenant: ${phoneMatch.name})';
          continue;
        }

        // Check for duplicate unit (if unit is occupied)
        final unitMatch = existingTenants.where((t) => t.unitNumber.trim().toLowerCase() == unitNumber.toLowerCase() && t.isActive).firstOrNull;
        if (unitMatch != null) {
          duplicateIndices.add(i);
          duplicateReasons[i] = 'Unit "$unitNumber" is already occupied by ${unitMatch.name}';
          continue;
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error checking duplicates: $e'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
    }

    setState(() {
      _duplicateRowIndices = duplicateIndices;
      _duplicateReasons = duplicateReasons;
    });
  }

  Future<void> _performImport() async {
    if (_parsedRows.isEmpty) return;

    final rowsToImport = _skipDuplicates
        ? _parsedRows.asMap().entries.where((e) => !_duplicateRowIndices.contains(e.key)).map((e) => e.value).toList()
        : _parsedRows;

    setState(() {
      _successCount = 0;
      _errorCount = 0;
      _importErrors = [];
      _isImporting = true;
      _totalRowsToImport = rowsToImport.length;
      _currentStep = 4; // Move to results step
    });

    for (final row in rowsToImport) {
      try {
        // Use empty strings or defaults for missing fields
        await TenantService.createTenant(
          facilityId: widget.facilityId,
          name: (row['name'] as String? ?? '').trim(),
          email: (row['email'] as String? ?? '').trim().isEmpty 
              ? 'pending@example.com' // Placeholder email if not provided
              : (row['email'] as String).trim(),
          phone: (row['phone'] as String? ?? '').trim().isEmpty 
              ? '000-000-0000' // Placeholder phone if not provided
              : (row['phone'] as String).trim(),
          unitNumber: (row['unitNumber'] as String? ?? '').trim(),
          monthlyRate: (row['monthlyRate'] as double? ?? 0.0),
          notes: (row['notes'] as String? ?? '').trim().isEmpty 
              ? 'Imported from CSV - please complete tenant information'
              : (row['notes'] as String).trim(),
        );

        setState(() {
          _successCount++;
        });
      } catch (e) {
        final rowNum = row['_rowNumber'] as int? ?? 0;
        setState(() {
          _errorCount++;
          _importErrors.add('Row $rowNum: $e');
        });
      }
    }

    setState(() {
      _isImporting = false;
    });

    // Refresh tenant list
    ref.invalidate(facilityTenantsProvider(widget.facilityId));
  }

  @override
  Widget build(BuildContext context) {
    // Note: This screen is inside ShellRoute with AppShell, so we don't use ModernPageWrapper
    // AppShell already provides Scaffold, sidebar, and top bar
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title
          Text(
            'Import Tenants from CSV',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 24),
          // Stepper
          Expanded(
            child: Stepper(
              currentStep: _currentStep,
              onStepContinue: _handleStepContinue,
              onStepCancel: _handleStepCancel,
              onStepTapped: (step) {
                if (step < _currentStep) {
                  setState(() {
                    _currentStep = step;
                  });
                }
              },
              steps: [
                _buildUploadStep(),
                _buildMappingStep(),
                _buildPreviewStep(),
                _buildDuplicatesStep(),
                _buildResultsStep(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Step _buildUploadStep() {
    return Step(
      title: const Text('Upload CSV File'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // How to Export instructions (Step 1 — before user uploads)
          Card(
            color: AppTheme.info.withOpacity(0.1),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.help_outline, color: AppTheme.info),
                      const SizedBox(width: 8),
                      const Text(
                        'How to Export Your Tenant List',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text('If you have tenant data in Excel, Google Sheets, or another system:', style: TextStyle(fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  _buildInstructionItem('1', 'Open your spreadsheet (Excel, Google Sheets, etc.)'),
                  _buildInstructionItem('2', 'Click "File" → "Download" or "Save As"'),
                  _buildInstructionItem('3', 'Choose "CSV (Comma Separated Values)" format'),
                  _buildInstructionItem('4', 'Save the file to your computer'),
                  _buildInstructionItem('5', 'Come back here and click "Choose CSV File" below'),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Don\'t have a file yet? Download a sample CSV to see the format:',
                          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: _downloadSampleCsv,
                        icon: const Icon(Icons.download, size: 16),
                        label: const Text('Download Sample'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryBlue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Select a CSV file containing tenant data. The file should have a header row with column names.',
            style: TextStyle(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 24),
          if (_csvData == null)
            ElevatedButton.icon(
              onPressed: _pickCsvFile,
              icon: const Icon(Icons.upload_file),
              label: const Text('Choose CSV File'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(16),
              ),
            )
          else
            Card(
              color: AppTheme.success.withOpacity(0.1),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.check_circle, color: AppTheme.success),
                        const SizedBox(width: 8),
                        Text(
                          'File loaded: ${_csvData!.length - 1} row${_csvData!.length - 1 == 1 ? '' : 's'}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Columns: ${_csvHeaders!.join(", ")}',
                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      isActive: _currentStep >= 0,
      state: _csvData == null ? StepState.indexed : StepState.complete,
    );
  }

  Step _buildMappingStep() {
    // Safety check - should not happen but prevents crash
    if (_csvHeaders == null || _csvHeaders!.isEmpty) {
      return Step(
        title: const Text('Map Columns'),
        content: const Card(
          color: AppTheme.error,
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Error: No CSV file loaded. Please go back and upload a CSV file first.',
              style: TextStyle(color: AppTheme.textOnDark),
            ),
          ),
        ),
        isActive: _currentStep >= 1,
        state: StepState.error,
      );
    }

    // Check if required fields are mapped
    final nameIsMapped = _columnMapping.containsKey('name') && _columnMapping['name'] != null && _columnMapping['name']!.isNotEmpty;

    return Step(
      title: const Text('Map Columns'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Mapping Instructions with Examples
          Card(
            color: AppTheme.success.withOpacity(0.05),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Match Your Columns to Our Fields',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Below, we\'ve tried to automatically match your CSV columns. Please review and adjust if needed.',
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.warning.withOpacity(0.1),
                      border: Border.all(color: AppTheme.warning),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info, color: AppTheme.warning, size: 20),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Only "Full Name" is required. Unit Number, Phone, Email, and Rate can be added later.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          
          // Required field warning if not mapped
          if (!nameIsMapped)
            Container(
              padding: const EdgeInsets.all(16),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: AppTheme.error.withOpacity(0.1),
                border: Border.all(color: AppTheme.error, width: 2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning, color: AppTheme.error, size: 32),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      '⚠️ You MUST map "Full Name" to continue!\n\nSelect which column contains the tenant\'s name from the dropdown below.',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
          
          // Field mapping dropdowns with examples
          ..._tenantFields.map((field) {
            final fieldKey = field['key'] as String;
            final isRequired = field['required'] == true;
            final examples = _getFieldExamples(fieldKey);
            
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    value: _columnMapping[fieldKey],
                    decoration: InputDecoration(
                      labelText: '${field['label']}${isRequired ? ' *' : ' (Optional)'}',
                      border: OutlineInputBorder(
                        borderSide: BorderSide(
                          color: isRequired && !_columnMapping.containsKey(fieldKey) ? AppTheme.error : AppTheme.borderLight,
                          width: isRequired && !_columnMapping.containsKey(fieldKey) ? 2 : 1,
                        ),
                      ),
                      helperText: examples,
                      helperMaxLines: 2,
                    ),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('-- Not Mapped --')),
                      ..._csvHeaders!.map((header) {
                        return DropdownMenuItem(
                          value: header,
                          child: Text(header),
                        );
                      }),
                    ],
                    onChanged: (value) {
                      setState(() {
                        if (value == null) {
                          _columnMapping.remove(fieldKey);
                        } else {
                          _columnMapping[fieldKey] = value;
                        }
                      });
                    },
                  ),
                ],
              ),
            );
          }),
        ],
      ),
      isActive: _currentStep >= 1,
      state: _currentStep > 1 ? StepState.complete : StepState.indexed,
    );
  }
  
  // Helper widget for instruction items
  Widget _buildInstructionItem(String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: AppTheme.primaryBlue,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(
                number,
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(text, style: const TextStyle(fontSize: 14)),
            ),
          ),
        ],
      ),
    );
  }
  
  // Get example text for field
  String _getFieldExamples(String fieldKey) {
    switch (fieldKey) {
      case 'name':
        return 'Examples: "John Smith", "Jane Doe"';
      case 'email':
        return 'Examples: "john@email.com", "jane.doe@gmail.com"';
      case 'phone':
        return 'Examples: "(555) 123-4567", "5551234567"';
      case 'unitNumber':
        return 'Examples: "A-101", "Unit 5", "Storage 42"';
      case 'monthlyRate':
        return 'Examples: "150", "89.99", "\$75.00"';
      case 'notes':
        return 'Any additional information about the tenant';
      default:
        return '';
    }
  }
  
  // Download sample CSV file
  void _downloadSampleCsv() {
    final sampleCsv = 'Name,Email,Phone,Unit Number,Monthly Rate,Notes\n'
        'John Smith,john.smith@email.com,(555) 123-4567,A-101,150.00,New tenant\n'
        'Jane Doe,jane.doe@gmail.com,555-234-5678,B-205,89.99,Transferred from Unit A-50\n'
        'Bob Johnson,bob@example.com,5551112222,C-310,125.50,';
    
    // Create blob and download (web)
    final bytes = utf8.encode(sampleCsv);
    final blob = html.Blob([bytes], 'text/csv');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.document.createElement('a') as html.AnchorElement
      ..href = url
      ..style.display = 'none'
      ..download = 'sample_tenants.csv';
    html.document.body?.children.add(anchor);
    anchor.click();
    html.document.body?.children.remove(anchor);
    html.Url.revokeObjectUrl(url);
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sample CSV downloaded! Open it in Excel to see the format.'),
          backgroundColor: AppTheme.success,
        ),
      );
    }
  }

  Step _buildPreviewStep() {
    // Safety check
    if (_csvData == null || _csvHeaders == null) {
      return Step(
        title: const Text('Preview & Validate'),
        content: const Card(
          color: AppTheme.warning,
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text('Please complete previous steps first.'),
          ),
        ),
        isActive: _currentStep >= 2,
        state: StepState.indexed,
      );
    }

    return Step(
      title: Text('Preview & Validate (${_parsedRows.length} valid rows)'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_validationErrors.isNotEmpty) ...[
            Card(
              color: AppTheme.error.withOpacity(0.1),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Validation Errors:',
                      style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.error),
                    ),
                    const SizedBox(height: 8),
                    ..._validationErrors.take(10).map((error) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(error, style: const TextStyle(fontSize: 12)),
                        )),
                    if (_validationErrors.length > 10)
                      Text(
                        '... and ${_validationErrors.length - 10} more errors',
                        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (_parsedRows.isNotEmpty) ...[
            const Text(
              'Preview of parsed data (first 5 rows):',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ..._parsedRows.take(5).map((row) {
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Name: ${row['name']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text('Email: ${row['email']}'),
                      Text('Phone: ${row['phone']}'),
                      Text('Unit: ${row['unitNumber']}'),
                      Text('Rate: \$${row['monthlyRate']}'),
                    ],
                  ),
                ),
              );
            }),
            if (_parsedRows.length > 5)
              Text(
                '... and ${_parsedRows.length - 5} more rows',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
          ],
        ],
      ),
      isActive: _currentStep >= 2,
      state: _currentStep > 2 ? StepState.complete : StepState.indexed,
    );
  }

  Step _buildDuplicatesStep() {
    // Safety check
    if (_parsedRows.isEmpty) {
      return Step(
        title: const Text('Handle Duplicates'),
        content: const Card(
          color: AppTheme.warning,
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text('Please complete previous steps first.'),
          ),
        ),
        isActive: _currentStep >= 3,
        state: StepState.indexed,
      );
    }

    return Step(
      title: Text('Handle Duplicates (${_duplicateRowIndices.length} found)'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_duplicateRowIndices.isEmpty)
            const Card(
              color: AppTheme.success,
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(Icons.check_circle, color: AppTheme.textOnDark),
                    SizedBox(width: 8),
                    Text(
                      'No duplicates found!',
                      style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.textOnDark),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            SwitchListTile(
              title: const Text('Skip Duplicates'),
              subtitle: const Text('If enabled, duplicate rows will be skipped during import'),
              value: _skipDuplicates,
              onChanged: (value) {
                setState(() {
                  _skipDuplicates = value;
                });
              },
            ),
            const SizedBox(height: 16),
            const Text(
              'Duplicate rows:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ..._duplicateRowIndices.take(10).map((index) {
              final row = _parsedRows[index];
              final reason = _duplicateReasons[index] ?? 'Unknown duplicate';
              return Card(
                color: AppTheme.warning.withOpacity(0.1),
                margin: const EdgeInsets.only(bottom: 8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Row ${row['_rowNumber']}: ${row['name']}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(reason, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    ],
                  ),
                ),
              );
            }),
            if (_duplicateRowIndices.length > 10)
              Text(
                '... and ${_duplicateRowIndices.length - 10} more duplicates',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
          ],
        ],
      ),
      isActive: _currentStep >= 3,
      state: _currentStep > 3 ? StepState.complete : StepState.indexed,
    );
  }

  Step _buildResultsStep() {
    final totalProcessed = _successCount + _errorCount;
    final isComplete = !_isImporting && (_totalRowsToImport == 0 || totalProcessed >= _totalRowsToImport);

    return Step(
      title: const Text('Import Results'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            color: isComplete 
                ? AppTheme.success.withOpacity(0.1)
                : AppTheme.warning.withOpacity(0.1),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  if (isComplete)
                    const Icon(Icons.check_circle, color: AppTheme.success, size: 48)
                  else
                    const SizedBox(
                      width: 48,
                      height: 48,
                      child: CircularProgressIndicator(),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    isComplete ? 'Import Complete!' : 'Import Pending...',
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  if (_isImporting)
                    Text(
                      'Processing: $_successCount of $_totalRowsToImport tenant${_totalRowsToImport == 1 ? '' : 's'}',
                      style: const TextStyle(fontSize: 16),
                    )
                  else
                    Text('Successfully imported: $_successCount tenant${_successCount == 1 ? '' : 's'}'),
                  if (_errorCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Errors: $_errorCount',
                        style: const TextStyle(color: AppTheme.error),
                      ),
                    ),
                  if (_isImporting && _totalRowsToImport > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Total to import: $_totalRowsToImport',
                        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (_importErrors.isNotEmpty) ...[
            const SizedBox(height: 16),
            Card(
              color: AppTheme.error.withOpacity(0.1),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Import Errors:',
                      style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.error),
                    ),
                    const SizedBox(height: 8),
                    ..._importErrors.take(10).map((error) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(error, style: const TextStyle(fontSize: 12)),
                        )),
                    if (_importErrors.length > 10)
                      Text(
                        '... and ${_importErrors.length - 10} more errors',
                        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                      ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _isImporting ? null : () {
              context.go(AppRoute.tenants);
            },
            child: const Text('Back to Tenants List'),
          ),
        ],
      ),
      isActive: _currentStep >= 4,
      state: StepState.complete,
    );
  }

  void _handleStepContinue() {
    switch (_currentStep) {
      case 0:
        if (_csvData != null) {
          setState(() {
            _currentStep = 1;
          });
        }
        break;
      case 1:
        _validateAndParse();
        // Allow continuing if we have at least some valid rows (even with warnings)
        if (_parsedRows.isNotEmpty) {
          setState(() {
            _currentStep = 2;
          });
        }
        break;
      case 2:
        setState(() {
          _currentStep = 3;
        });
        break;
      case 3:
        _performImport();
        break;
      case 4:
        context.go(AppRoute.tenants);
        break;
    }
  }

  void _handleStepCancel() {
    if (_currentStep > 0) {
      setState(() {
        _currentStep--;
      });
    } else {
      context.go(AppRoute.tenants);
    }
  }
}
