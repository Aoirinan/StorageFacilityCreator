import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/facility_model.dart';
import '../providers/facility_provider.dart';
import '../services/facility_service.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';

class DelinquencyRulesScreen extends ConsumerStatefulWidget {
  final String facilityId;

  const DelinquencyRulesScreen({
    super.key,
    required this.facilityId,
  });

  @override
  ConsumerState<DelinquencyRulesScreen> createState() => _DelinquencyRulesScreenState();
}

class _DelinquencyRulesScreenState extends ConsumerState<DelinquencyRulesScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  bool _isSaving = false;

  // Form controllers
  late TextEditingController _gracePeriodController;
  late TextEditingController _baseLateFeeController;
  late TextEditingController _dailyLateFeeController;
  late TextEditingController _noticeDaysController;
  late TextEditingController _finalNoticeDaysController;
  late TextEditingController _lienDaysController;
  late TextEditingController _lockoutDaysController;

  bool _enableAutoLateFees = true;
  bool _enableAutoNotices = true;
  bool _enableAutoLockout = false;

  @override
  void initState() {
    super.initState();
    _gracePeriodController = TextEditingController(text: '3');
    _baseLateFeeController = TextEditingController(text: '25.00');
    _dailyLateFeeController = TextEditingController(text: '5.00');
    _noticeDaysController = TextEditingController(text: '7');
    _finalNoticeDaysController = TextEditingController(text: '14');
    _lienDaysController = TextEditingController(text: '30');
    _lockoutDaysController = TextEditingController(text: '45');
    _loadFacilitySettings();
  }

  @override
  void dispose() {
    _gracePeriodController.dispose();
    _baseLateFeeController.dispose();
    _dailyLateFeeController.dispose();
    _noticeDaysController.dispose();
    _finalNoticeDaysController.dispose();
    _lienDaysController.dispose();
    _lockoutDaysController.dispose();
    super.dispose();
  }

  Future<void> _loadFacilitySettings() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final facility = await FacilityService.getFacility(widget.facilityId);
      if (facility != null && facility.billingSettings != null) {
        final settings = facility.billingSettings!;
        
        setState(() {
          _gracePeriodController.text = (settings['gracePeriodDays'] ?? 3).toString();
          _baseLateFeeController.text = (settings['baseLateFee'] ?? 25.0).toStringAsFixed(2);
          _dailyLateFeeController.text = (settings['dailyLateFee'] ?? 5.0).toStringAsFixed(2);
          _noticeDaysController.text = (settings['noticeDays'] ?? 7).toString();
          _finalNoticeDaysController.text = (settings['finalNoticeDays'] ?? 14).toString();
          _lienDaysController.text = (settings['lienDays'] ?? 30).toString();
          _lockoutDaysController.text = (settings['lockoutDays'] ?? 45).toString();
          _enableAutoLateFees = settings['enableAutoLateFees'] ?? true;
          _enableAutoNotices = settings['enableAutoNotices'] ?? true;
          _enableAutoLockout = settings['enableAutoLockout'] ?? false;
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
      final billingSettings = {
        'gracePeriodDays': int.parse(_gracePeriodController.text),
        'baseLateFee': double.parse(_baseLateFeeController.text),
        'dailyLateFee': double.parse(_dailyLateFeeController.text),
        'noticeDays': int.parse(_noticeDaysController.text),
        'finalNoticeDays': int.parse(_finalNoticeDaysController.text),
        'lienDays': int.parse(_lienDaysController.text),
        'lockoutDays': int.parse(_lockoutDaysController.text),
        'enableAutoLateFees': _enableAutoLateFees,
        'enableAutoNotices': _enableAutoNotices,
        'enableAutoLockout': _enableAutoLockout,
      };

      await FacilityService.updateFacility(
        facilityId: widget.facilityId,
        billingSettings: billingSettings,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Delinquency rules saved successfully'),
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
    return ModernPageWrapper(
      currentRoute: '/settings',
      title: 'Delinquency Rules',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildSectionHeader('Late Fee Settings'),
                    const SizedBox(height: 16),
                    _buildNumberField(
                      controller: _gracePeriodController,
                      label: 'Grace Period (Days)',
                      helper: 'Number of days before late fees are applied',
                    ),
                    const SizedBox(height: 16),
                    _buildNumberField(
                      controller: _baseLateFeeController,
                      label: 'Base Late Fee (\$)',
                      helper: 'Initial late fee amount',
                      isDecimal: true,
                    ),
                    const SizedBox(height: 16),
                    _buildNumberField(
                      controller: _dailyLateFeeController,
                      label: 'Daily Late Fee (\$)',
                      helper: 'Additional fee per day after grace period',
                      isDecimal: true,
                    ),
                    const SizedBox(height: 24),
                    _buildSectionHeader('Notice Settings'),
                    const SizedBox(height: 16),
                    _buildNumberField(
                      controller: _noticeDaysController,
                      label: 'First Notice (Days Overdue)',
                      helper: 'Days overdue before sending first notice',
                    ),
                    const SizedBox(height: 16),
                    _buildNumberField(
                      controller: _finalNoticeDaysController,
                      label: 'Final Notice (Days Overdue)',
                      helper: 'Days overdue before sending final notice',
                    ),
                    const SizedBox(height: 16),
                    _buildNumberField(
                      controller: _lienDaysController,
                      label: 'Lien Filing (Days Overdue)',
                      helper: 'Days overdue before filing lien',
                    ),
                    const SizedBox(height: 24),
                    _buildSectionHeader('Lockout Settings'),
                    const SizedBox(height: 16),
                    _buildNumberField(
                      controller: _lockoutDaysController,
                      label: 'Lockout (Days Overdue)',
                      helper: 'Days overdue before disabling gate access',
                    ),
                    const SizedBox(height: 24),
                    _buildSectionHeader('Automation Settings'),
                    const SizedBox(height: 16),
                    SwitchListTile(
                      title: const Text('Automatically Apply Late Fees'),
                      subtitle: const Text('Late fees will be applied automatically based on rules'),
                      value: _enableAutoLateFees,
                      onChanged: (value) {
                        setState(() {
                          _enableAutoLateFees = value;
                        });
                      },
                    ),
                    SwitchListTile(
                      title: const Text('Automatically Send Notices'),
                      subtitle: const Text('Late notices will be sent automatically via email/SMS'),
                      value: _enableAutoNotices,
                      onChanged: (value) {
                        setState(() {
                          _enableAutoNotices = value;
                        });
                      },
                    ),
                    SwitchListTile(
                      title: const Text('Automatically Trigger Lockout'),
                      subtitle: const Text('Gate access will be disabled automatically when lockout threshold is reached'),
                      value: _enableAutoLockout,
                      onChanged: (value) {
                        setState(() {
                          _enableAutoLockout = value;
                        });
                      },
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _isSaving ? null : _saveSettings,
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          backgroundColor: AppTheme.primaryBlue,
                          foregroundColor: Colors.white,
                        ),
                        child: _isSaving
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Text('Save Settings'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.bold,
        color: AppTheme.primaryBlue,
      ),
    );
  }

  Widget _buildNumberField({
    required TextEditingController controller,
    required String label,
    String? helper,
    bool isDecimal = false,
  }) {
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        border: const OutlineInputBorder(),
        prefixText: isDecimal ? '\$' : null,
      ),
      keyboardType: isDecimal
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.number,
      validator: (value) {
        if (value == null || value.isEmpty) {
          return 'This field is required';
        }
        if (isDecimal) {
          final parsed = double.tryParse(value);
          if (parsed == null || parsed < 0) {
            return 'Please enter a valid amount';
          }
        } else {
          final parsed = int.tryParse(value);
          if (parsed == null || parsed < 0) {
            return 'Please enter a valid number';
          }
        }
        return null;
      },
    );
  }
}

