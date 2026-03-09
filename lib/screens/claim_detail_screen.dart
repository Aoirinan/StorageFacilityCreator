import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import '../models/claim_model.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../services/tenant_service.dart';

/// Screen for viewing/editing a single insurance claim
class ClaimDetailScreen extends StatefulWidget {
  final String facilityId;
  final String? claimId;
  final bool isNewClaim;
  final String? tenantId; // Optional: pre-select tenant for new claim

  const ClaimDetailScreen({
    super.key,
    required this.facilityId,
    this.claimId,
    required this.isNewClaim,
    this.tenantId,
  });

  @override
  State<ClaimDetailScreen> createState() => _ClaimDetailScreenState();
}

class _ClaimDetailScreenState extends State<ClaimDetailScreen> {
  final _formKey = GlobalKey<FormState>();
  final _claimAmountController = TextEditingController();
  final _deductibleAmountController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _managerStatementController = TextEditingController();
  final _tenantStatementController = TextEditingController();
  final _adjusterEmailController = TextEditingController();

  bool _isLoading = false;
  bool _isSaving = false;
  ClaimStatus _selectedStatus = ClaimStatus.pending;
  ClaimType _selectedClaimType = ClaimType.other;
  DateTime _selectedIncidentDate = DateTime.now();
  String? _selectedTenantId;
  String? _selectedLeaseId;
  List<String> _documentUrls = [];
  List<String> _uploadedFileNames = [];

  @override
  void initState() {
    super.initState();
    if (widget.tenantId != null) {
      _selectedTenantId = widget.tenantId;
    }
    if (!widget.isNewClaim && widget.claimId != null) {
      _loadClaim();
    }
  }

  @override
  void dispose() {
    _claimAmountController.dispose();
    _deductibleAmountController.dispose();
    _descriptionController.dispose();
    _managerStatementController.dispose();
    _tenantStatementController.dispose();
    _adjusterEmailController.dispose();
    super.dispose();
  }

  Future<void> _loadClaim() async {
    if (widget.claimId == null) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final doc = await FirebaseFirestore.instance
          .collection('facilities')
          .doc(widget.facilityId)
          .collection('claims')
          .doc(widget.claimId!)
          .get();

      if (doc.exists) {
        final claim = ClaimModel.fromFirestore(doc);
        setState(() {
          _selectedStatus = claim.status;
          _selectedClaimType = claim.claimType;
          _selectedIncidentDate = claim.incidentDate;
          _selectedTenantId = claim.tenantId;
          _selectedLeaseId = claim.leaseId;
          _claimAmountController.text = claim.claimAmount.toStringAsFixed(2);
          _deductibleAmountController.text = claim.deductibleAmount.toStringAsFixed(2);
          _descriptionController.text = claim.description;
          _managerStatementController.text = claim.managerStatement ?? '';
          _tenantStatementController.text = claim.tenantStatement ?? '';
          _adjusterEmailController.text = claim.adjusterEmail ?? '';
          _documentUrls = List<String>.from(claim.documentUrls);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading claim: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _uploadDocument() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty) {
        setState(() {
          _isSaving = true;
        });

        final storage = FirebaseStorage.instance;
        final uploadUrls = <String>[];

        for (final file in result.files) {
          if (file.bytes != null && file.name.isNotEmpty) {
            final fileName = 'claims/${widget.facilityId}/${DateTime.now().millisecondsSinceEpoch}_${file.name}';
            final ref = storage.ref().child(fileName);

            await ref.putData(file.bytes!);
            final downloadUrl = await ref.getDownloadURL();
            uploadUrls.add(downloadUrl);
          }
        }

        setState(() {
          _documentUrls.addAll(uploadUrls);
          _uploadedFileNames.addAll(result.files.map((f) => f.name));
          _isSaving = false;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Documents uploaded successfully'),
              backgroundColor: AppTheme.success,
            ),
          );
        }
      }
    } catch (e) {
      setState(() {
        _isSaving = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error uploading documents: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _saveClaim() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedTenantId == null || _selectedTenantId!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a tenant'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final functions = FirebaseFunctions.instance;

      final data = {
        'facilityId': widget.facilityId,
        'tenantId': _selectedTenantId,
        'leaseId': _selectedLeaseId,
        'incidentDate': _selectedIncidentDate.toIso8601String(),
        'claimType': _selectedClaimType.name,
        'claimAmount': double.parse(_claimAmountController.text),
        'deductibleAmount': double.parse(_deductibleAmountController.text),
        'description': _descriptionController.text,
        'managerStatement': _managerStatementController.text.isEmpty
            ? null
            : _managerStatementController.text,
        'tenantStatement': _tenantStatementController.text.isEmpty
            ? null
            : _tenantStatementController.text,
        'documentUrls': _documentUrls,
        'adjusterEmail': _adjusterEmailController.text.isEmpty
            ? null
            : _adjusterEmailController.text,
      };

      final result = await functions.httpsCallable('submitClaim').call(data);
      final claimId = result.data['claimId'] as String;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Claim submitted successfully'),
            backgroundColor: AppTheme.success,
          ),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error submitting claim: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      setState(() {
        _isSaving = false;
      });
    }
  }

  Future<void> _selectTenant() async {
    // Simple tenant selection - in production, use a proper dialog or navigation
    final tenants = await TenantService.getTenantsForFacility(widget.facilityId);
    
    if (mounted && tenants.isNotEmpty) {
      final selected = await showDialog<String>(
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
                  subtitle: Text('Unit ${tenant.unitNumber}'),
                  onTap: () => Navigator.pop(context, tenant.id),
                );
              },
            ),
          ),
        ),
      );

      if (selected != null) {
        setState(() {
          _selectedTenantId = selected;
        });
      }
    }
  }

  Future<void> _selectIncidentDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedIncidentDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );

    if (picked != null) {
      setState(() {
        _selectedIncidentDate = picked;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentRoute = GoRouter.of(context).routeInformationProvider.value.location ?? '/insurance/claims';
    return _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  // Tenant Selection
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Tenant Information',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 16),
                          ListTile(
                            title: Text(_selectedTenantId != null ? 'Selected Tenant' : 'Select Tenant'),
                            subtitle: _selectedTenantId != null
                                ? FutureBuilder<DocumentSnapshot>(
                                    future: FirebaseFirestore.instance
                                        .collection('facilities')
                                        .doc(widget.facilityId)
                                        .collection('tenants')
                                        .doc(_selectedTenantId!)
                                        .get(),
                                    builder: (context, snapshot) {
                                      if (snapshot.hasData) {
                                        final data = snapshot.data!.data() as Map<String, dynamic>?;
                                        return Text('${data?['name'] ?? 'Unknown'} - Unit ${data?['unitNumber'] ?? 'N/A'}');
                                      }
                                      return const Text('Loading...');
                                    },
                                  )
                                : const Text('Tap to select tenant'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: _selectTenant,
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Claim Details
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Claim Details',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 16),

                          // Incident Date
                          ListTile(
                            title: const Text('Incident Date'),
                            subtitle: Text(_formatDate(_selectedIncidentDate)),
                            trailing: const Icon(Icons.calendar_today),
                            onTap: _selectIncidentDate,
                          ),

                          const SizedBox(height: 8),

                          // Claim Type
                          DropdownButtonFormField<ClaimType>(
                            value: _selectedClaimType,
                            decoration: const InputDecoration(
                              labelText: 'Claim Type',
                              border: OutlineInputBorder(),
                            ),
                            items: ClaimType.values.map((type) {
                              return DropdownMenuItem(
                                value: type,
                                child: Text(type.displayName),
                              );
                            }).toList(),
                            onChanged: (value) {
                              if (value != null) {
                                setState(() {
                                  _selectedClaimType = value;
                                });
                              }
                            },
                          ),

                          const SizedBox(height: 16),

                          // Claim Amount
                          TextFormField(
                            controller: _claimAmountController,
                            decoration: const InputDecoration(
                              labelText: 'Claim Amount',
                              prefixText: '\$',
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            validator: (value) {
                              if (value == null || value.isEmpty) {
                                return 'Please enter claim amount';
                              }
                              final amount = double.tryParse(value);
                              if (amount == null || amount <= 0) {
                                return 'Please enter a valid amount';
                              }
                              return null;
                            },
                          ),

                          const SizedBox(height: 16),

                          // Deductible Amount
                          TextFormField(
                            controller: _deductibleAmountController,
                            decoration: const InputDecoration(
                              labelText: 'Deductible Amount',
                              prefixText: '\$',
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            validator: (value) {
                              if (value == null || value.isEmpty) {
                                return 'Please enter deductible amount';
                              }
                              final amount = double.tryParse(value);
                              if (amount == null || amount < 0) {
                                return 'Please enter a valid amount';
                              }
                              return null;
                            },
                          ),

                          const SizedBox(height: 16),

                          // Description
                          TextFormField(
                            controller: _descriptionController,
                            decoration: const InputDecoration(
                              labelText: 'Description',
                              border: OutlineInputBorder(),
                            ),
                            maxLines: 4,
                            validator: (value) {
                              if (value == null || value.isEmpty) {
                                return 'Please enter a description';
                              }
                              return null;
                            },
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Statements
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Statements',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 16),

                          TextFormField(
                            controller: _managerStatementController,
                            decoration: const InputDecoration(
                              labelText: 'Manager Statement',
                              border: OutlineInputBorder(),
                              helperText: 'Optional',
                            ),
                            maxLines: 4,
                          ),

                          const SizedBox(height: 16),

                          TextFormField(
                            controller: _tenantStatementController,
                            decoration: const InputDecoration(
                              labelText: 'Tenant Statement',
                              border: OutlineInputBorder(),
                              helperText: 'Optional',
                            ),
                            maxLines: 4,
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Documents
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Documents',
                                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                              ),
                              FilledButton.icon(
                                onPressed: _isSaving ? null : _uploadDocument,
                                icon: const Icon(Icons.upload),
                                label: const Text('Upload'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          if (_documentUrls.isEmpty)
                            const Text(
                              'No documents uploaded',
                              style: TextStyle(color: Colors.grey),
                            )
                          else
                            ..._documentUrls.asMap().entries.map((entry) {
                              return ListTile(
                                leading: const Icon(Icons.description),
                                title: Text(entry.value.split('/').last),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete),
                                  onPressed: () {
                                    setState(() {
                                      _documentUrls.removeAt(entry.key);
                                    });
                                  },
                                ),
                              );
                            }),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Adjuster Email
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Adjuster Information',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _adjusterEmailController,
                            decoration: const InputDecoration(
                              labelText: 'Adjuster Email',
                              border: OutlineInputBorder(),
                              helperText: 'Email address for claim notifications',
                            ),
                            keyboardType: TextInputType.emailAddress,
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Submit Button
                  FilledButton.icon(
                    onPressed: _isSaving ? null : _saveClaim,
                    icon: _isSaving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save),
                    label: Text(_isSaving ? 'Submitting...' : 'Submit Claim'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                    ),
                  ),
                ],
              ),
            );
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }
}

