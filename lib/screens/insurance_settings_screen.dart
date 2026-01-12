import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../widgets/keyboard_scrollable.dart';
import '../theme/app_theme.dart';
import '../services/facility_service.dart';

/// Screen for managing Tenant Protection Program (TPP) and insurance settings
class InsuranceSettingsScreen extends StatefulWidget {
  final String facilityId;

  const InsuranceSettingsScreen({
    super.key,
    required this.facilityId,
  });

  @override
  State<InsuranceSettingsScreen> createState() => _InsuranceSettingsScreenState();
}

class _InsuranceSettingsScreenState extends State<InsuranceSettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _defaultCoverageAmountController = TextEditingController();
  final _monthlyFeeController = TextEditingController();
  final _auditGracePeriodController = TextEditingController();
  
  bool _isLoading = false;
  bool _isSaving = false;
  bool _enableAutoProtectMoveIn = false;
  bool _enableAutoProtectAudit = false;
  String _selectedCoverageLevel = 'minimum';
  String? _defaultAdjusterEmail;

  @override
  void initState() {
    super.initState();
    _loadFacilitySettings();
  }

  @override
  void dispose() {
    _defaultCoverageAmountController.dispose();
    _monthlyFeeController.dispose();
    _auditGracePeriodController.dispose();
    super.dispose();
  }

  Future<void> _loadFacilitySettings() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final facility = await FacilityService.getFacility(widget.facilityId);
      if (facility != null) {
        final settings = facility.insuranceSettings;
        
        setState(() {
          _enableAutoProtectMoveIn = settings?['autoProtectMoveIn'] ?? false;
          _enableAutoProtectAudit = settings?['autoProtectAudit'] ?? false;
          _selectedCoverageLevel = settings?['defaultCoverageLevel'] ?? 'minimum';
          _defaultCoverageAmountController.text = (settings?['defaultCoverageAmount'] ?? 5000.0).toStringAsFixed(2);
          _monthlyFeeController.text = (settings?['defaultMonthlyFee'] ?? 15.0).toStringAsFixed(2);
          _auditGracePeriodController.text = (settings?['auditGracePeriodDays'] ?? 45).toString();
          _defaultAdjusterEmail = settings?['defaultAdjusterEmail'];
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading settings: $e'),
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

  Future<void> _saveSettings() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSaving = true;
    });

    try {
      final insuranceSettings = {
        'autoProtectMoveIn': _enableAutoProtectMoveIn,
        'autoProtectAudit': _enableAutoProtectAudit,
        'defaultCoverageLevel': _selectedCoverageLevel,
        'defaultCoverageAmount': double.parse(_defaultCoverageAmountController.text),
        'defaultMonthlyFee': double.parse(_monthlyFeeController.text),
        'auditGracePeriodDays': int.parse(_auditGracePeriodController.text),
        if (_defaultAdjusterEmail != null && _defaultAdjusterEmail!.isNotEmpty)
          'defaultAdjusterEmail': _defaultAdjusterEmail,
      };

      await FacilityService.updateFacility(
        facilityId: widget.facilityId,
        insuranceSettings: insuranceSettings,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Insurance settings saved successfully'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving settings: $e'),
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

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    
    return Form(
      key: _formKey,
      child: KeyboardScrollable(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title
              Text(
                'Insurance Settings',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: AppTheme.primaryBlue,
                ),
              ),
              const SizedBox(height: 24),
              
              // Auto-Protect Features
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Auto-Protect Features',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 16),
                          
                          // Auto-Protect Move-In
                          SwitchListTile(
                            title: const Text('Auto-Protect Move-In'),
                            subtitle: const Text(
                              'Automatically enroll new tenants in TPP after 14 days if no insurance proof is provided',
                            ),
                            value: _enableAutoProtectMoveIn,
                            onChanged: (value) {
                              setState(() {
                                _enableAutoProtectMoveIn = value;
                              });
                            },
                          ),
                          
                          const Divider(),
                          
                          // Auto-Protect Audit
                          SwitchListTile(
                            title: const Text('Auto-Protect Audit'),
                            subtitle: const Text(
                              'Notify existing tenants about insurance requirement and auto-enroll after grace period',
                            ),
                            value: _enableAutoProtectAudit,
                            onChanged: (value) {
                              setState(() {
                                _enableAutoProtectAudit = value;
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 24),
                  
                  // Default Coverage Settings
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Default Coverage Settings',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 16),
                          
                          // Coverage Level
                          DropdownButtonFormField<String>(
                            value: _selectedCoverageLevel,
                            decoration: const InputDecoration(
                              labelText: 'Coverage Level',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.shield),
                            ),
                            items: const [
                              DropdownMenuItem(value: 'minimum', child: Text('Minimum')),
                              DropdownMenuItem(value: 'standard', child: Text('Standard')),
                              DropdownMenuItem(value: 'premium', child: Text('Premium')),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                setState(() {
                                  _selectedCoverageLevel = value;
                                });
                              }
                            },
                          ),
                          
                          const SizedBox(height: 16),
                          
                          // Default Coverage Amount
                          TextFormField(
                            controller: _defaultCoverageAmountController,
                            decoration: const InputDecoration(
                              labelText: 'Default Coverage Amount',
                              prefixText: '\$',
                              border: OutlineInputBorder(),
                              helperText: 'Default coverage amount for TPP',
                              prefixIcon: Icon(Icons.attach_money),
                            ),
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            validator: (value) {
                              if (value == null || value.isEmpty) {
                                return 'Please enter coverage amount';
                              }
                              final amount = double.tryParse(value);
                              if (amount == null || amount <= 0) {
                                return 'Please enter a valid amount';
                              }
                              return null;
                            },
                          ),
                          
                          const SizedBox(height: 16),
                          
                          // Monthly Fee
                          TextFormField(
                            controller: _monthlyFeeController,
                            decoration: const InputDecoration(
                              labelText: 'Monthly Fee',
                              prefixText: '\$',
                              border: OutlineInputBorder(),
                              helperText: 'Monthly fee for TPP enrollment',
                              prefixIcon: Icon(Icons.attach_money),
                            ),
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            validator: (value) {
                              if (value == null || value.isEmpty) {
                                return 'Please enter monthly fee';
                              }
                              final amount = double.tryParse(value);
                              if (amount == null || amount <= 0) {
                                return 'Please enter a valid amount';
                              }
                              return null;
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 24),
                  
                  // Audit Settings
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Audit Settings',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 16),
                          
                          // Grace Period Days
                          TextFormField(
                            controller: _auditGracePeriodController,
                            decoration: const InputDecoration(
                              labelText: 'Grace Period (Days)',
                              border: OutlineInputBorder(),
                              helperText: 'Days to wait after notification before auto-enrollment',
                              prefixIcon: Icon(Icons.calendar_today),
                            ),
                            keyboardType: TextInputType.number,
                            validator: (value) {
                              if (value == null || value.isEmpty) {
                                return 'Please enter grace period';
                              }
                              final days = int.tryParse(value);
                              if (days == null || days <= 0) {
                                return 'Please enter a valid number of days';
                              }
                              return null;
                            },
                          ),
                          
                          const SizedBox(height: 16),
                          
                          // Default Adjuster Email
                          TextFormField(
                            initialValue: _defaultAdjusterEmail,
                            decoration: const InputDecoration(
                              labelText: 'Default Adjuster Email',
                              border: OutlineInputBorder(),
                              helperText: 'Email address for claim notifications',
                              prefixIcon: Icon(Icons.email),
                            ),
                            keyboardType: TextInputType.emailAddress,
                            onChanged: (value) {
                              _defaultAdjusterEmail = value.isEmpty ? null : value;
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 24),
                  
                  // Save Button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isSaving ? null : _saveSettings,
                      icon: _isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save),
                      label: Text(_isSaving ? 'Saving...' : 'Save Settings'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryBlue,
                        foregroundColor: AppTheme.textOnDark,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

