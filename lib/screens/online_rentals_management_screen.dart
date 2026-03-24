import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../models/facility_model.dart';
import '../models/unit_model.dart';
import '../services/facility_map_v2_service.dart';
import '../services/facility_public_service.dart';
import '../services/facility_service.dart';
import '../services/unit_service.dart';
import '../theme/app_theme.dart';

class OnlineRentalsManagementScreen extends StatefulWidget {
  final String facilityId;

  const OnlineRentalsManagementScreen({
    super.key,
    required this.facilityId,
  });

  @override
  State<OnlineRentalsManagementScreen> createState() =>
      _OnlineRentalsManagementScreenState();
}

class _OnlineRentalsManagementScreenState
    extends State<OnlineRentalsManagementScreen> {
  bool _isLoading = true;
  bool _isSaving = false;
  String? _error;
  FacilityModel? _facility;

  final TextEditingController _slugController = TextEditingController();
  bool _publicRentalsEnabled = false;
  bool _publicPricingEnabled = true;
  bool _publicUnitNumbersEnabled = true;
  bool _allowAutoAssign = true;
  bool _allowUnitSelection = true;
  bool _showAvailabilityCount = true;
  bool _hideUnavailableTypes = true;
  Set<String> _enabledPublicUnitTypes = <String>{};
  Set<String> _availableUnitTypes = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _slugController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final facility = await FacilityService.getFacility(widget.facilityId);
      final settings =
          await FacilityPublicService.getPublicSettings(widget.facilityId);
      final publicSlug = await FacilityMapV2Service.getPublicSlugForFacility(
          widget.facilityId);
      final units = await UnitService.getUnitsForFacility(widget.facilityId);
      final types = units.map((u) => u.unitType).toSet();

      if (!mounted) return;
      setState(() {
        _facility = facility;
        _publicRentalsEnabled = settings?.publicRentalsEnabled ?? false;
        _publicPricingEnabled = settings?.publicPricingEnabled ?? true;
        _publicUnitNumbersEnabled = settings?.publicUnitNumbersEnabled ?? true;
        _allowAutoAssign = settings?.allowAutoAssign ?? true;
        _allowUnitSelection = settings?.allowUnitSelection ?? true;
        _showAvailabilityCount = settings?.showAvailabilityCount ?? true;
        _hideUnavailableTypes = settings?.hideUnavailableTypes ?? true;
        _enabledPublicUnitTypes =
            settings?.enabledPublicUnitTypes.toSet() ?? <String>{};
        _availableUnitTypes = types;
        _slugController.text =
            (settings?.publicRentalSlug?.trim().isNotEmpty ?? false)
                ? settings!.publicRentalSlug!
                : (publicSlug ?? widget.facilityId.toLowerCase());
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load online rental settings: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _save() async {
    final slug = _normalizedSlug(_slugController.text);
    if (slug.isEmpty) {
      setState(() {
        _error = 'Please enter a valid public rental slug.';
      });
      return;
    }
    if (!_allowAutoAssign && !_allowUnitSelection) {
      setState(() {
        _error =
            'Enable either auto-assign or specific unit selection for renters.';
      });
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      await FacilityPublicService.updatePublicSettings(
        facilityId: widget.facilityId,
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
        facilityId: widget.facilityId,
        slug: slug,
      );
      await FacilityMapV2Service.publishCurrentDraft(
          facilityId: widget.facilityId);

      if (!mounted) return;
      setState(() {
        _slugController.text = slug;
        _isSaving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Online rental settings saved and published.'),
          backgroundColor: AppTheme.success,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _error = 'Failed to save settings: $e';
      });
    }
  }

  String _normalizedSlug(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9-]'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }

  String get _slugPreview {
    final slug = _normalizedSlug(_slugController.text);
    return slug.isEmpty ? widget.facilityId.toLowerCase() : slug;
  }

  Future<void> _copy(String label, String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied to clipboard'),
        backgroundColor: AppTheme.success,
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _facility == null) {
      return Center(child: Text(_error!));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            const Text(
              'Online Rentals',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            IconButton(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
            ),
          ],
        ),
        const SizedBox(height: 8),
                    Text(
                      _facility?.name ?? 'Facility',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Manage SFC-hosted public rental links for your website, social pages, SMS, and email.',
                      style: TextStyle(color: AppTheme.textSecondary),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _slugController,
                      decoration: const InputDecoration(
                        labelText: 'Public Rental Slug',
                        hintText: 'your-facility',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.link),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      value: _publicRentalsEnabled,
                      onChanged: (v) =>
                          setState(() => _publicRentalsEnabled = v),
                      title: const Text('Enable Public Online Rentals'),
                    ),
                    SwitchListTile(
                      value: _publicPricingEnabled,
                      onChanged: (v) =>
                          setState(() => _publicPricingEnabled = v),
                      title: const Text('Show Pricing Publicly'),
                    ),
                    SwitchListTile(
                      value: _publicUnitNumbersEnabled,
                      onChanged: (v) =>
                          setState(() => _publicUnitNumbersEnabled = v),
                      title: const Text('Show Exact Unit Numbers'),
                    ),
                    SwitchListTile(
                      value: _allowAutoAssign,
                      onChanged: (v) => setState(() => _allowAutoAssign = v),
                      title: const Text('Allow Auto-Assign'),
                    ),
                    SwitchListTile(
                      value: _allowUnitSelection,
                      onChanged: (v) => setState(() => _allowUnitSelection = v),
                      title: const Text('Allow Specific Unit Selection'),
                    ),
                    SwitchListTile(
                      value: _showAvailabilityCount,
                      onChanged: (v) =>
                          setState(() => _showAvailabilityCount = v),
                      title: const Text('Show Availability Count'),
                    ),
                    SwitchListTile(
                      value: _hideUnavailableTypes,
                      onChanged: (v) =>
                          setState(() => _hideUnavailableTypes = v),
                      title: const Text('Hide Unavailable Types'),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Publicly Visible Unit Types',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: () {
                        final types = (_availableUnitTypes.isEmpty
                                ? UnitType.values.map((e) => e.name).toSet()
                                : _availableUnitTypes)
                            .toList()
                          ..sort();
                        return types.map((type) {
                          final selected =
                              _enabledPublicUnitTypes.contains(type);
                          return FilterChip(
                            selected: selected,
                            label: Text(_unitTypeLabel(type)),
                            onSelected: (checked) {
                              setState(() {
                                if (checked) {
                                  _enabledPublicUnitTypes.add(type);
                                } else {
                                  _enabledPublicUnitTypes.remove(type);
                                }
                              });
                            },
                          );
                        }).toList();
                      }(),
                    ),
                    const SizedBox(height: 16),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _LinkRow(
                              label: 'Main Rent Link',
                              value: FacilityPublicService.getPublicRentUrl(
                                  _slugPreview),
                              onCopy: _copy,
                            ),
                            const Divider(),
                            _LinkRow(
                              label: 'All Available Units Link',
                              value: FacilityPublicService
                                  .getPublicAvailableUnitsUrl(_slugPreview),
                              onCopy: _copy,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!,
                          style: const TextStyle(color: AppTheme.error)),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () =>
                                context.push('/f/$_slugPreview/rent'),
                            icon: const Icon(Icons.open_in_new),
                            label: const Text('Preview Public Page'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isSaving ? null : _save,
                            icon: _isSaving
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.save),
                            label: Text(_isSaving ? 'Saving...' : 'Save'),
                          ),
                        ),
                      ],
                    ),
      ],
    );
  }
}

class _LinkRow extends StatelessWidget {
  final String label;
  final String value;
  final Future<void> Function(String label, String value) onCopy;

  const _LinkRow({
    required this.label,
    required this.value,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: () {
            unawaited(onCopy(label, value));
          },
          icon: const Icon(Icons.copy, size: 18),
          tooltip: 'Copy Link',
        ),
      ],
    );
  }
}
