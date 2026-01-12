import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import '../providers/auth_provider.dart';
import '../services/facility_service.dart';
import '../models/facility_model.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';
import '../utils/error_message_helper.dart';

class FacilityEditScreen extends ConsumerStatefulWidget {
  final FacilityModel facility;

  const FacilityEditScreen({
    super.key,
    required this.facility,
  });

  @override
  ConsumerState<FacilityEditScreen> createState() => _FacilityEditScreenState();
}

class _FacilityEditScreenState extends ConsumerState<FacilityEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _addressController;
  late final TextEditingController _phoneController;
  late final TextEditingController _emailController;
  late final TextEditingController _gracePeriodController;
  late final TextEditingController _lateFeeAmountController;
  
  String? _selectedTimeZone;
  String _lateFeeType = 'flat';
  
  bool _isLoading = false;
  String? _errorMessage;
  
  // Common time zones
  final List<String> _timeZones = [
    'America/New_York',
    'America/Chicago',
    'America/Denver',
    'America/Phoenix',
    'America/Los_Angeles',
    'America/Anchorage',
    'Pacific/Honolulu',
  ];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.facility.name);
    _addressController = TextEditingController(text: widget.facility.address ?? '');
    _phoneController = TextEditingController(text: widget.facility.phone ?? '');
    _emailController = TextEditingController(text: widget.facility.email ?? '');
    
    // Initialize billing settings
    final billingSettings = widget.facility.billingSettings;
    if (billingSettings != null) {
      _gracePeriodController = TextEditingController(
        text: (billingSettings['gracePeriodDays'] ?? 5).toString(),
      );
      _lateFeeType = billingSettings['lateFeeType'] ?? 'flat';
      _lateFeeAmountController = TextEditingController(
        text: (billingSettings['lateFeeAmount'] ?? 25.0).toStringAsFixed(2),
      );
    } else {
      _gracePeriodController = TextEditingController(text: '5');
      _lateFeeAmountController = TextEditingController(text: '25.00');
    }
    
    _selectedTimeZone = widget.facility.timeZone;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _gracePeriodController.dispose();
    _lateFeeAmountController.dispose();
    super.dispose();
  }

  Future<void> _updateFacility() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (kDebugMode) {
        print('🔄 Updating facility: ${widget.facility.id}');
      }

      // Build billing settings
      Map<String, dynamic>? billingSettings;
      try {
        final gracePeriod = int.tryParse(_gracePeriodController.text.trim()) ?? 5;
        final lateFeeAmount = double.tryParse(_lateFeeAmountController.text.trim()) ?? 25.0;
        billingSettings = {
          'gracePeriodDays': gracePeriod,
          'lateFeeType': _lateFeeType,
          'lateFeeAmount': lateFeeAmount,
        };
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ Error building billing settings: $e');
        }
      }

      await FacilityService.updateFacility(
        facilityId: widget.facility.id,
        name: _nameController.text.trim(),
        address: _addressController.text.trim().isEmpty ? null : _addressController.text.trim(),
        phone: _phoneController.text.trim().isEmpty ? null : _phoneController.text.trim(),
        email: _emailController.text.trim().isEmpty ? null : _emailController.text.trim(),
        timeZone: _selectedTimeZone,
        billingSettings: billingSettings,
      );

      if (kDebugMode) {
        print('✅ Facility updated successfully');
      }

      if (mounted) {
        setState(() {
          _isLoading = false;
        });

        // Show success message
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Facility updated successfully'),
            backgroundColor: AppTheme.success,
          ),
        );

        // Navigate back
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error updating facility: $e');
      }

      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);

    return authState.when(
      data: (user) {
        if (user == null) {
          return const Scaffold(
            body: Center(child: Text('Please sign in to edit facilities')),
          );
        }

        return ModernPageWrapper(
          currentRoute: '/facilities',
          title: 'Edit Facility',
          onNavigate: (route) {
            ModernNavigationService.navigateToRoute(context, route);
          },
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Form(
              key: _formKey,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Facility Information',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.primaryBlue,
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Facility Name
                    TextFormField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: 'Facility Name *',
                        hintText: 'e.g., Keepsake Self Storage',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.business),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Please enter a facility name';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),

                    // Address
                    TextFormField(
                      controller: _addressController,
                      decoration: const InputDecoration(
                        labelText: 'Address',
                        hintText: '123 Main St, City, State 12345',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.location_on),
                      ),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 16),

                    // Phone
                    TextFormField(
                      controller: _phoneController,
                      decoration: const InputDecoration(
                        labelText: 'Phone Number',
                        hintText: '(555) 123-4567',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.phone),
                      ),
                      keyboardType: TextInputType.phone,
                    ),
                    const SizedBox(height: 16),

                    // Email
                    TextFormField(
                      controller: _emailController,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        hintText: 'contact@facility.com',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.email),
                      ),
                      keyboardType: TextInputType.emailAddress,
                    ),
                    const SizedBox(height: 24),

                    // Divider for settings section
                    const Divider(),
                    const SizedBox(height: 16),

                    const Text(
                      'Settings',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.primaryBlue,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Time Zone
                    DropdownButtonFormField<String>(
                      value: _selectedTimeZone,
                      decoration: const InputDecoration(
                        labelText: 'Time Zone',
                        hintText: 'Select time zone',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.access_time),
                      ),
                      items: _timeZones.map((tz) {
                        return DropdownMenuItem<String>(
                          value: tz,
                          child: Text(tz.replaceAll('America/', '').replaceAll('Pacific/', '')),
                        );
                      }).toList(),
                      onChanged: (value) {
                        setState(() {
                          _selectedTimeZone = value;
                        });
                      },
                    ),
                    const SizedBox(height: 24),

                    // Billing Settings Section
                    const Text(
                      'Billing Settings',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.primaryBlue,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Grace Period
                    TextFormField(
                      controller: _gracePeriodController,
                      decoration: const InputDecoration(
                        labelText: 'Grace Period (Days)',
                        hintText: '5',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.calendar_today),
                        helperText: 'Number of days before late fees apply',
                      ),
                      keyboardType: TextInputType.number,
                      validator: (value) {
                        if (value != null && value.isNotEmpty) {
                          final days = int.tryParse(value);
                          if (days == null || days < 0) {
                            return 'Please enter a valid number of days';
                          }
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),

                    // Late Fee Type
                    DropdownButtonFormField<String>(
                      value: _lateFeeType,
                      decoration: const InputDecoration(
                        labelText: 'Late Fee Type',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.attach_money),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'flat', child: Text('Flat Amount')),
                        DropdownMenuItem(value: 'percentage', child: Text('Percentage')),
                      ],
                      onChanged: (value) {
                        setState(() {
                          _lateFeeType = value ?? 'flat';
                        });
                      },
                    ),
                    const SizedBox(height: 16),

                    // Late Fee Amount
                    TextFormField(
                      controller: _lateFeeAmountController,
                      decoration: InputDecoration(
                        labelText: _lateFeeType == 'flat' ? 'Late Fee Amount (\$)' : 'Late Fee Percentage (%)',
                        hintText: _lateFeeType == 'flat' ? '25.00' : '5.0',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.money),
                        helperText: _lateFeeType == 'flat'
                            ? 'Fixed late fee amount in dollars'
                            : 'Late fee as percentage of rent',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      validator: (value) {
                        if (value != null && value.isNotEmpty) {
                          final amount = double.tryParse(value);
                          if (amount == null || amount < 0) {
                            return 'Please enter a valid amount';
                          }
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 24),

                    // Error Message
                    if (_errorMessage != null)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.error.withOpacity(0.1),
                          border: Border.all(color: AppTheme.error),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error, color: AppTheme.error),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _errorMessage!,
                                style: TextStyle(color: AppTheme.error),
                              ),
                            ),
                          ],
                        ),
                      ),

                    if (_errorMessage != null) const SizedBox(height: 16),

                    // Update Button
                    ElevatedButton(
                      onPressed: _isLoading ? null : _updateFacility,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryBlue,
                        foregroundColor: AppTheme.textOnDark,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: _isLoading
                          ? const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(AppTheme.textOnDark),
                                  ),
                                ),
                                SizedBox(width: 12),
                                Text('Updating Facility...'),
                              ],
                            )
                          : const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.save),
                                SizedBox(width: 8),
                                Text('Update Facility'),
                              ],
                            ),
                    ),

                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stackTrace) => Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error, size: 64, color: AppTheme.error),
              const SizedBox(height: 16),
              const Text('Error loading user data'),
              const SizedBox(height: 8),
              Text(ErrorMessageHelper.getUserFriendlyMessage(error)),
            ],
          ),
        ),
      ),
    );
  }
}

