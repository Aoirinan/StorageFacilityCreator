import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../providers/auth_provider.dart';
import '../router/app_route.dart';
import '../services/facility_service.dart';
import '../services/facility_stats_service.dart';
import '../models/facility_model.dart';
import '../models/unit_model.dart';
import '../theme/app_theme.dart';
import '../services/facility_map_v2_service.dart';
import '../services/facility_public_service.dart';
import '../utils/error_message_helper.dart';
import '../utils/time_zone_helper.dart';
import '../constants/facility_capacity.dart';

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
  late final TextEditingController _totalUnitsController;

  String? _selectedTimeZone;
  String _lateFeeType = 'flat';

  bool _isLoading = false;
  String? _errorMessage;

  bool _isLoadingPublicSettings = true;
  bool _isSavingPublicSettings = false;
  String? _publicSettingsError;
  final TextEditingController _publicRentalSlugController =
      TextEditingController();
  bool _publicRentalsEnabled = false;
  bool _publicPricingEnabled = true;
  bool _publicUnitNumbersEnabled = true;
  bool _allowAutoAssign = true;
  bool _allowUnitSelection = true;
  bool _showAvailabilityCount = true;
  bool _hideUnavailableTypes = true;
  Set<String> _enabledPublicUnitTypes = <String>{};

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
    _addressController =
        TextEditingController(text: widget.facility.address ?? '');
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

    _totalUnitsController = TextEditingController(
      text: widget.facility.totalUnits > 0
          ? widget.facility.totalUnits.toString()
          : '',
    );
    _selectedTimeZone =
        widget.facility.timeZone ?? TimeZoneHelper.defaultTimeZoneId;
    _loadPublicRentalSettings();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _gracePeriodController.dispose();
    _lateFeeAmountController.dispose();
    _totalUnitsController.dispose();
    _publicRentalSlugController.dispose();
    super.dispose();
  }

  Future<void> _loadPublicRentalSettings() async {
    setState(() {
      _isLoadingPublicSettings = true;
      _publicSettingsError = null;
    });
    try {
      final settings =
          await FacilityPublicService.getPublicSettings(widget.facility.id);
      final slug = settings?.publicRentalSlug?.trim();
      final fallbackSlug = await FacilityMapV2Service.getPublicSlugForFacility(
              widget.facility.id) ??
          widget.facility.id.toLowerCase();
      final safeSlug = (slug == null || slug.isEmpty) ? fallbackSlug : slug;

      if (!mounted) return;
      setState(() {
        _publicRentalsEnabled = settings?.publicRentalsEnabled ?? false;
        _publicPricingEnabled = settings?.publicPricingEnabled ?? true;
        _publicUnitNumbersEnabled = settings?.publicUnitNumbersEnabled ?? true;
        _allowAutoAssign = settings?.allowAutoAssign ?? true;
        _allowUnitSelection = settings?.allowUnitSelection ?? true;
        _showAvailabilityCount = settings?.showAvailabilityCount ?? true;
        _hideUnavailableTypes = settings?.hideUnavailableTypes ?? true;
        _enabledPublicUnitTypes =
            settings?.enabledPublicUnitTypes.toSet() ?? <String>{};
        _publicRentalSlugController.text = safeSlug;
        _isLoadingPublicSettings = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _publicSettingsError = ErrorMessageHelper.getUserFriendlyMessage(e);
        _isLoadingPublicSettings = false;
      });
    }
  }

  Future<void> _savePublicRentalSettings() async {
    final rawSlug = _publicRentalSlugController.text.trim();
    final slug = rawSlug
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9-]'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    if (slug.isEmpty) {
      setState(() {
        _publicSettingsError = 'Public rental slug is required.';
      });
      return;
    }
    if (!_allowAutoAssign && !_allowUnitSelection) {
      setState(() {
        _publicSettingsError =
            'Enable auto-assign or unit selection so renters can complete checkout.';
      });
      return;
    }

    setState(() {
      _isSavingPublicSettings = true;
      _publicSettingsError = null;
    });

    try {
      await FacilityPublicService.updatePublicSettings(
        facilityId: widget.facility.id,
        enabled: true,
        publicRentalsEnabled: _publicRentalsEnabled,
        publicPricingEnabled: _publicPricingEnabled,
        publicUnitNumbersEnabled: _publicUnitNumbersEnabled,
        allowAutoAssign: _allowAutoAssign,
        allowUnitSelection: _allowUnitSelection,
        showAvailabilityCount: _showAvailabilityCount,
        hideUnavailableTypes: _hideUnavailableTypes,
        enabledPublicUnitTypes: _enabledPublicUnitTypes.toList(),
        publicRentalSlug: slug,
      );

      await FacilityMapV2Service.setPublicSlug(
        facilityId: widget.facility.id,
        slug: slug,
      );
      await FacilityMapV2Service.publishCurrentDraft(
          facilityId: widget.facility.id);

      if (!mounted) return;
      setState(() {
        _publicRentalSlugController.text = slug;
        _isSavingPublicSettings = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Public rental links saved and published.'),
          backgroundColor: AppTheme.success,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSavingPublicSettings = false;
        _publicSettingsError = ErrorMessageHelper.getUserFriendlyMessage(e);
      });
    }
  }

  Future<void> _copyToClipboard(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied to clipboard'),
        backgroundColor: AppTheme.success,
      ),
    );
  }

  String get _slugPreview {
    final slug = _publicRentalSlugController.text.trim().toLowerCase();
    return slug.isEmpty ? widget.facility.id.toLowerCase() : slug;
  }

  String _unitTypeLabel(String raw) {
    return raw
        .replaceAllMapped(RegExp(r'([A-Z])'), (m) => ' ${m.group(1)}')
        .trim()
        .split(' ')
        .where((part) => part.isNotEmpty)
        .map((part) => part[0].toUpperCase() + part.substring(1))
        .join(' ');
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
        final gracePeriod =
            int.tryParse(_gracePeriodController.text.trim()) ?? 5;
        final lateFeeAmount =
            double.tryParse(_lateFeeAmountController.text.trim()) ?? 25.0;
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

      final totalUnits = int.tryParse(_totalUnitsController.text.trim()) ?? 0;
      await FacilityService.updateFacility(
        facilityId: widget.facility.id,
        name: _nameController.text.trim(),
        address: _addressController.text.trim().isEmpty
            ? null
            : _addressController.text.trim(),
        phone: _phoneController.text.trim().isEmpty
            ? null
            : _phoneController.text.trim(),
        email: _emailController.text.trim().isEmpty
            ? null
            : _emailController.text.trim(),
        timeZone: _selectedTimeZone,
        billingSettings: billingSettings,
        totalUnits: totalUnits,
      );

      await FacilityStatsService.reconcileUnitsToCapacity(widget.facility.id);

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
        if (context.canPop()) {
          context.pop();
        } else {
          context.go(AppRoute.facilities);
        }
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

  Widget _sectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);

    return authState.when(
      data: (user) {
        if (user == null) {
          return const Center(child: Text('Please sign in to edit facilities'));
        }

        return Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16.0),
            // Clamping avoids extra scroll extent on web when content is shorter than the viewport
            // (AlwaysScrollableScrollPhysics from app builder was exposing a gray gap while scrolling).
            physics: const ClampingScrollPhysics(),
            children: [
              Text(
                'Edit Facility',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.facility.name,
                style: const TextStyle(
                  fontSize: 16,
                  color: AppTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 20),
              _sectionTitle('Facility Information'),
              const SizedBox(height: 16),

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

                  const SizedBox(height: 8),
                  _sectionTitle('Settings'),
                  const SizedBox(height: 16),

                  // Site-wide capacity (max units); unit rows are added in the unit list, not auto-created here.
                  TextFormField(
                    controller: _totalUnitsController,
                    decoration: InputDecoration(
                      labelText: 'Unit capacity (max)',
                      hintText: 'e.g., 50',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.grid_view),
                      helperText:
                          'Maximum units this site can hold (1–$kMaxFacilityCapacityUnits). '
                          'Change this when your build-out grows; add unit records under Units.',
                    ),
                    keyboardType: TextInputType.number,
                    validator: (value) {
                      final raw = value?.trim() ?? '';
                      if (raw.isEmpty) {
                        return 'Total units is required.';
                      }
                      final n = int.tryParse(raw);
                      if (n == null || n < 1 || n > kMaxFacilityCapacityUnits) {
                        return 'Total units must be between 1 and $kMaxFacilityCapacityUnits.';
                      }
                      return null;
                    },
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
                        child: Text(TimeZoneHelper.displayLabel(tz)),
                      );
                    }).toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedTimeZone = value;
                      });
                    },
                  ),
                  const SizedBox(height: 24),

                  _sectionTitle('Billing Settings'),
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
                      DropdownMenuItem(
                          value: 'flat', child: Text('Flat Amount')),
                      DropdownMenuItem(
                          value: 'percentage', child: Text('Percentage')),
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
                      labelText: _lateFeeType == 'flat'
                          ? 'Late Fee Amount (\$)'
                          : 'Late Fee Percentage (%)',
                      hintText: _lateFeeType == 'flat' ? '25.00' : '5.0',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.money),
                      helperText: _lateFeeType == 'flat'
                          ? 'Fixed late fee amount in dollars'
                          : 'Late fee as percentage of rent',
                    ),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
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

                  const SizedBox(height: 8),
                  _sectionTitle('Public Rental Links'),
                  const SizedBox(height: 8),
                  const Text(
                    'Generate hosted online rental links your team can paste on your website, email, SMS, and social pages.',
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  if (_isLoadingPublicSettings)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: LinearProgressIndicator(),
                    )
                  else ...[
                    TextFormField(
                      controller: _publicRentalSlugController,
                      decoration: const InputDecoration(
                        labelText: 'Public URL Name',
                        hintText: 'example-facility',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.link),
                        helperText:
                            'Used in hosted public URLs: /f/{slug}/rent',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      value: _publicRentalsEnabled,
                      onChanged: (value) =>
                          setState(() => _publicRentalsEnabled = value),
                      title: const Text('Enable Public Online Rentals'),
                    ),
                    SwitchListTile(
                      value: _publicPricingEnabled,
                      onChanged: (value) =>
                          setState(() => _publicPricingEnabled = value),
                      title: const Text('Show Public Pricing'),
                    ),
                    SwitchListTile(
                      value: _publicUnitNumbersEnabled,
                      onChanged: (value) =>
                          setState(() => _publicUnitNumbersEnabled = value),
                      title: const Text('Show Exact Unit Numbers Publicly'),
                    ),
                    SwitchListTile(
                      value: _allowAutoAssign,
                      onChanged: (value) =>
                          setState(() => _allowAutoAssign = value),
                      title: const Text('Allow Auto-Assign'),
                    ),
                    SwitchListTile(
                      value: _allowUnitSelection,
                      onChanged: (value) =>
                          setState(() => _allowUnitSelection = value),
                      title: const Text('Allow Specific Unit Selection'),
                    ),
                    SwitchListTile(
                      value: _showAvailabilityCount,
                      onChanged: (value) =>
                          setState(() => _showAvailabilityCount = value),
                      title: const Text('Show Availability Count'),
                    ),
                    SwitchListTile(
                      value: _hideUnavailableTypes,
                      onChanged: (value) =>
                          setState(() => _hideUnavailableTypes = value),
                      title: const Text('Hide Unavailable Categories/Types'),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Public Unit Categories',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: UnitType.values.map((type) {
                        final value = type.name;
                        final selected =
                            _enabledPublicUnitTypes.contains(value);
                        return FilterChip(
                          selected: selected,
                          label: Text(_unitTypeLabel(value)),
                          onSelected: (checked) {
                            setState(() {
                              if (checked) {
                                _enabledPublicUnitTypes.add(value);
                              } else {
                                _enabledPublicUnitTypes.remove(value);
                              }
                            });
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 12),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _PublicLinkRow(
                              label: 'Main Rent Link',
                              value: FacilityPublicService.getPublicRentUrl(
                                  _slugPreview),
                              onCopy: _copyToClipboard,
                            ),
                            const Divider(),
                            _PublicLinkRow(
                              label: 'All Available Units Link',
                              value: FacilityPublicService
                                  .getPublicAvailableUnitsUrl(_slugPreview),
                              onCopy: _copyToClipboard,
                            ),
                            if (_enabledPublicUnitTypes.isNotEmpty) ...[
                              const Divider(),
                              ...(() {
                                final types = _enabledPublicUnitTypes.toList()
                                  ..sort();
                                return types.map((type) {
                                  final categorySlug = type
                                      .toLowerCase()
                                      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
                                      .replaceAll(RegExp(r'-{2,}'), '-')
                                      .replaceAll(RegExp(r'^-|-$'), '');
                                  return _PublicLinkRow(
                                    label: '${_unitTypeLabel(type)} Link',
                                    value: FacilityPublicService
                                        .getPublicCategoryUrl(
                                      _slugPreview,
                                      categorySlug,
                                    ),
                                    onCopy: _copyToClipboard,
                                  );
                                }).toList();
                              })(),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () =>
                                context.push('/f/${_slugPreview}/rent'),
                            icon: const Icon(Icons.open_in_new),
                            label: const Text('Preview Public Page'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isSavingPublicSettings
                                ? null
                                : _savePublicRentalSettings,
                            icon: _isSavingPublicSettings
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.save),
                            label: Text(_isSavingPublicSettings
                                ? 'Saving...'
                                : 'Save Public Rental Settings'),
                          ),
                        ),
                      ],
                    ),
                  ],
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
                  if (_publicSettingsError != null)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppTheme.error.withOpacity(0.1),
                        border: Border.all(color: AppTheme.error),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error, color: AppTheme.error),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _publicSettingsError!,
                              style: const TextStyle(color: AppTheme.error),
                            ),
                          ),
                        ],
                      ),
                    ),

                  if (_publicSettingsError != null) const SizedBox(height: 16),

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
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      AppTheme.textOnDark),
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
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error, size: 64, color: AppTheme.error),
            const SizedBox(height: 16),
            const Text('Error loading user data'),
            const SizedBox(height: 8),
            Text(ErrorMessageHelper.getUserFriendlyMessage(error)),
          ],
        ),
      ),
    );
  }
}

class _PublicLinkRow extends StatelessWidget {
  final String label;
  final String value;
  final Future<void> Function(String label, String value) onCopy;

  const _PublicLinkRow({
    required this.label,
    required this.value,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Copy Link',
            onPressed: () {
              unawaited(onCopy(label, value));
            },
            icon: const Icon(Icons.copy, size: 18),
          ),
        ],
      ),
    );
  }
}
