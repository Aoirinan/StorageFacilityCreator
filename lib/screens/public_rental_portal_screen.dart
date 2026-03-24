import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/services/facility_map_v2_service.dart';
import 'package:sfcapp/services/public_rental_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

class PublicRentalPortalScreen extends StatefulWidget {
  final String? facilityId;
  final String? facilitySlug;
  final bool availableOnly;
  final String? initialCategorySlug;

  const PublicRentalPortalScreen({
    super.key,
    this.facilityId,
    this.facilitySlug,
    this.availableOnly = false,
    this.initialCategorySlug,
  });

  @override
  State<PublicRentalPortalScreen> createState() =>
      _PublicRentalPortalScreenState();
}

class _PublicRentalPortalScreenState extends State<PublicRentalPortalScreen> {
  bool _isLoading = true;
  String? _error;
  String? _facilitySlug;
  String? _facilityId;
  String _facilityName = 'Rent Online';
  String? _facilityDescription;
  String? _facilityPhone;
  String? _facilityLogoUrl;

  bool _publicRentalsEnabled = false;
  bool _publicPricingEnabled = true;
  bool _publicUnitNumbersEnabled = true;
  bool _allowAutoAssign = true;
  bool _allowUnitSelection = true;
  bool _showAvailabilityCount = true;
  bool _hideUnavailableTypes = true;
  Set<String> _enabledPublicUnitTypes = <String>{};

  List<_PublicUnitView> _units = <_PublicUnitView>[];
  String? _selectedCategorySlug;
  String? _preferredUnitId;
  String? _preferredUnitType;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final fromPathSlug = _getSlugFromPath();
      final resolvedSlug = widget.facilitySlug ??
          fromPathSlug ??
          await _resolveSlugFromFacility(widget.facilityId);

      if (resolvedSlug == null || resolvedSlug.isEmpty) {
        setState(() {
          _error = 'Public rental page not found for this facility.';
          _isLoading = false;
        });
        return;
      }

      final snapshot =
          await FacilityMapV2Service.getPublicSnapshotBySlug(resolvedSlug);
      if (snapshot == null) {
        setState(() {
          _error =
              'Public rental inventory is not published yet. Ask the facility owner to publish online rentals.';
          _isLoading = false;
        });
        return;
      }

      final settings = snapshot.publicSettings;
      final publicUnits = snapshot.units
          .map((raw) => _PublicUnitView.fromMap(raw))
          .where((u) => u.unitId.isNotEmpty)
          .toList();
      _preferredUnitId = Uri.base.queryParameters['unitId'];
      _preferredUnitType = Uri.base.queryParameters['unitType'];

      final enabledTypes =
          (settings['enabledPublicUnitTypes'] as List<dynamic>? ??
                  const <dynamic>[])
              .map((e) => e.toString())
              .where((e) => e.trim().isNotEmpty)
              .toSet();

      setState(() {
        _facilitySlug = resolvedSlug;
        _facilityId = snapshot.facilityId;
        _facilityName =
            settings['facilityName']?.toString().trim().isNotEmpty == true
                ? settings['facilityName'].toString()
                : 'Rent Online';
        _facilityDescription = settings['facilityDescription']?.toString();
        _facilityPhone = settings['facilityPhone']?.toString();
        _facilityLogoUrl = settings['facilityLogoUrl']?.toString();
        _publicRentalsEnabled = settings['publicRentalsEnabled'] == true;
        _publicPricingEnabled = settings['showPublicPricing'] != false;
        _publicUnitNumbersEnabled =
            settings['publicUnitNumbersEnabled'] != false;
        _allowAutoAssign = settings['allowAutoAssign'] != false;
        _allowUnitSelection = settings['allowUnitSelection'] != false;
        _showAvailabilityCount = settings['showAvailabilityCount'] != false;
        _hideUnavailableTypes = settings['hideUnavailableTypes'] != false;
        _enabledPublicUnitTypes = enabledTypes;
        _units = publicUnits;
        _selectedCategorySlug = widget.initialCategorySlug;
        _isLoading = false;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PublicRentalPortal] Failed to load public rental data: $e');
      }
      setState(() {
        _error = 'Unable to load public rental inventory.';
        _isLoading = false;
      });
    }
  }

  String? _getSlugFromPath() {
    final segments = Uri.base.pathSegments;
    if (segments.length >= 2 && segments[0] == 'f') {
      return segments[1];
    }
    return null;
  }

  Future<String?> _resolveSlugFromFacility(String? facilityId) async {
    if (facilityId == null || facilityId.isEmpty) return null;
    return FacilityMapV2Service.getPublicSlugForFacility(facilityId);
  }

  List<_UnitTypeGroup> get _groups {
    final filteredUnits = _units.where((u) {
      if (_enabledPublicUnitTypes.isNotEmpty &&
          !_enabledPublicUnitTypes.contains(u.unitType)) {
        return false;
      }
      if (widget.availableOnly &&
          !(u.status == 'available' || u.status == 'reserved')) {
        return false;
      }
      if (_selectedCategorySlug != null && _selectedCategorySlug!.isNotEmpty) {
        return u.categorySlug == _selectedCategorySlug;
      }
      return true;
    }).toList();

    final grouped = <String, _UnitTypeGroup>{};
    for (final unit in filteredUnits) {
      final key = '${unit.unitType}|${unit.size ?? 'unsized'}';
      grouped.putIfAbsent(
        key,
        () => _UnitTypeGroup(
          key: key,
          unitType: unit.unitType,
          categorySlug: unit.categorySlug,
          sizeLabel: unit.size ?? 'Size not specified',
        ),
      );
      grouped[key]!.addUnit(unit);
    }

    var groups = grouped.values.toList();
    if (_hideUnavailableTypes) {
      groups = groups.where((g) => g.availableUnits.isNotEmpty).toList();
    }

    groups.sort((a, b) {
      final preferredA = _isPreferredGroup(a);
      final preferredB = _isPreferredGroup(b);
      if (preferredA != preferredB) return preferredA ? -1 : 1;
      return a.sortLabel.compareTo(b.sortLabel);
    });
    return groups;
  }

  bool _isPreferredGroup(_UnitTypeGroup group) {
    if (_preferredUnitId != null &&
        group.units.any((u) => u.unitId == _preferredUnitId)) {
      return true;
    }
    if (_preferredUnitType == null || _preferredUnitType!.isEmpty) return false;
    final normalized = _preferredUnitType!.toLowerCase().trim();
    return group.unitType.toLowerCase() == normalized ||
        (group.sizeLabel?.toLowerCase().replaceAll(' ', '') ?? '') ==
            normalized.replaceAll(' ', '');
  }

  List<String> get _categorySlugs {
    final slugs = _units
        .map((u) => u.categorySlug)
        .where((slug) => slug.trim().isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return slugs;
  }

  String _displayCategory(String slug) {
    return slug
        .split('-')
        .where((part) => part.isNotEmpty)
        .map((part) => part[0].toUpperCase() + part.substring(1))
        .join(' ');
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error!, textAlign: TextAlign.center),
          ),
        ),
      );
    }

    final groups = _groups;
    return Scaffold(
      appBar: AppBar(
        title: Text(_facilityName),
        backgroundColor: AppTheme.primaryBlueDark,
        foregroundColor: AppTheme.textOnDark,
      ),
      body: Column(
        children: [
          _buildFacilityHeader(),
          if (_categorySlugs.isNotEmpty) _buildCategoryTabs(),
          Expanded(
            child: groups.isEmpty
                ? _buildEmptyState()
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: groups.length,
                    itemBuilder: (context, index) =>
                        _buildGroupCard(groups[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFacilityHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      color: AppTheme.primaryBlueLight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_facilityLogoUrl != null &&
              _facilityLogoUrl!.trim().isNotEmpty) ...[
            Image.network(
              _facilityLogoUrl!,
              height: 52,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
            const SizedBox(height: 8),
          ],
          Text(
            _facilityName,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          if (_facilityDescription != null &&
              _facilityDescription!.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              _facilityDescription!,
              style: const TextStyle(color: Colors.white70),
            ),
          ],
          if (_facilityPhone != null && _facilityPhone!.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.phone, size: 16, color: Colors.white70),
                const SizedBox(width: 6),
                Text(_facilityPhone!,
                    style: const TextStyle(color: Colors.white70)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCategoryTabs() {
    final slugs = _categorySlugs;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          ChoiceChip(
            label: const Text('All'),
            selected: _selectedCategorySlug == null,
            onSelected: (_) => setState(() => _selectedCategorySlug = null),
          ),
          ...slugs.map(
            (slug) => ChoiceChip(
              label: Text(_displayCategory(slug)),
              selected: _selectedCategorySlug == slug,
              onSelected: (_) => setState(() => _selectedCategorySlug = slug),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupCard(_UnitTypeGroup group) {
    final availableCount = group.availableUnits.length;
    final unavailable = availableCount == 0;
    final monthlyRate = group.lowestRate;
    final canRent = _publicRentalsEnabled &&
        !unavailable &&
        (_allowAutoAssign || _allowUnitSelection);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              group.title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            if (group.description != null &&
                group.description!.trim().isNotEmpty)
              Text(group.description!,
                  style: TextStyle(color: AppTheme.textSecondary)),
            if (_publicPricingEnabled && monthlyRate != null) ...[
              const SizedBox(height: 10),
              Text(
                '\$${monthlyRate.toStringAsFixed(2)}/month',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: AppTheme.primaryBlueDark,
                  fontSize: 18,
                ),
              ),
            ],
            if (_showAvailabilityCount) ...[
              const SizedBox(height: 10),
              Text(
                availableCount == 0
                    ? 'Currently unavailable'
                    : availableCount == 1
                        ? 'Only 1 left'
                        : '$availableCount available',
                style: TextStyle(
                  color:
                      availableCount == 0 ? AppTheme.error : AppTheme.success,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: canRent ? () => _handleRentNow(group) : null,
                child: Text(unavailable ? 'Unavailable' : 'Rent Now'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inventory_2_outlined,
                size: 56, color: AppTheme.textTertiary),
            const SizedBox(height: 12),
            const Text(
              'No rentable units are currently available online.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed:
                  _facilityPhone == null || _facilityPhone!.trim().isEmpty
                      ? null
                      : () {},
              child: Text(
                _facilityPhone == null || _facilityPhone!.trim().isEmpty
                    ? 'Check back soon'
                    : 'Call $_facilityPhone',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleRentNow(_UnitTypeGroup group) async {
    if (group.availableUnits.isEmpty || _facilityId == null) return;

    _PublicUnitView? selectedUnit;
    if (_allowAutoAssign && !_allowUnitSelection) {
      selectedUnit = group.availableUnits.first;
    } else if (!_allowAutoAssign && _allowUnitSelection) {
      selectedUnit = await _showUnitPicker(group.availableUnits);
      if (selectedUnit == null) return;
    } else {
      final choice = await _showAssignChoice();
      if (choice == null) return;
      if (choice == _AssignChoice.autoAssign) {
        selectedUnit = group.availableUnits.first;
      } else {
        selectedUnit = await _showUnitPicker(group.availableUnits);
        if (selectedUnit == null) return;
      }
    }
    if (!mounted) return;
    final selected = selectedUnit;

    final reservationPayload = await showDialog<Map<String, String?>>(
      context: context,
      builder: (context) => _ReservationDialog(
        title: _publicUnitNumbersEnabled
            ? 'Rent Unit ${selected.unitLabel ?? ''}'
            : 'Complete Rental Request',
        priceText: selected.monthlyRate != null
            ? '\$${selected.monthlyRate!.toStringAsFixed(2)}/month'
            : null,
      ),
    );

    if (reservationPayload == null) return;

    try {
      final reservation = await PublicRentalService.createReservation(
        facilityId: _facilityId!,
        unitId: selected.unitId,
        unitNumber: _publicUnitNumbersEnabled ? selected.unitLabel : null,
        email: reservationPayload['email']!,
        phone: reservationPayload['phone'],
        name: reservationPayload['name'],
        moveInDate: reservationPayload['moveInDate'] == null
            ? null
            : DateTime.parse(reservationPayload['moveInDate']!),
        expirationDuration: const Duration(minutes: 10),
        metadata: <String, dynamic>{
          'source': 'publicRentalLinks',
          'facilitySlug': _facilitySlug,
          'autoAssigned': !_allowUnitSelection,
          'requestedCategory': _selectedCategorySlug,
        },
      );

      if (!mounted) return;
      unawaited(
          context.push('/public-move-in?token=${reservation.moveInToken}'));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to continue rental: $e'),
          backgroundColor: AppTheme.error,
        ),
      );
    }
  }

  Future<_AssignChoice?> _showAssignChoice() async {
    return showDialog<_AssignChoice>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Choose Unit Selection'),
          content: const Text(
            'You can let us automatically assign a unit or choose a specific available unit.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            OutlinedButton(
              onPressed: () =>
                  Navigator.of(context).pop(_AssignChoice.autoAssign),
              child: const Text('Auto Assign'),
            ),
            ElevatedButton(
              onPressed: () =>
                  Navigator.of(context).pop(_AssignChoice.chooseSpecific),
              child: const Text('Choose Unit'),
            ),
          ],
        );
      },
    );
  }

  Future<_PublicUnitView?> _showUnitPicker(List<_PublicUnitView> units) async {
    return showDialog<_PublicUnitView>(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: const Text('Select Available Unit'),
          children: units
              .map(
                (unit) => SimpleDialogOption(
                  onPressed: () => Navigator.of(context).pop(unit),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _publicUnitNumbersEnabled
                              ? 'Unit ${unit.unitLabel}'
                              : unit.displayName,
                        ),
                      ),
                      if (_publicPricingEnabled && unit.monthlyRate != null)
                        Text('\$${unit.monthlyRate!.toStringAsFixed(2)}'),
                    ],
                  ),
                ),
              )
              .toList(),
        );
      },
    );
  }
}

class _PublicUnitView {
  final String unitId;
  final String unitType;
  final String categorySlug;
  final String? unitLabel;
  final String displayName;
  final String? size;
  final String? description;
  final String status;
  final bool isRentable;
  final double? monthlyRate;

  const _PublicUnitView({
    required this.unitId,
    required this.unitType,
    required this.categorySlug,
    required this.unitLabel,
    required this.displayName,
    required this.size,
    required this.description,
    required this.status,
    required this.isRentable,
    required this.monthlyRate,
  });

  factory _PublicUnitView.fromMap(Map<String, dynamic> map) {
    final unitType = map['unitType']?.toString().trim().isNotEmpty == true
        ? map['unitType'].toString()
        : 'standard';
    final unitLabel =
        map['unitLabel']?.toString() ?? map['unitNumber']?.toString();
    final categorySlug =
        map['categorySlug']?.toString().trim().isNotEmpty == true
            ? map['categorySlug'].toString()
            : _toSlug(unitType);
    return _PublicUnitView(
      unitId: map['unitId']?.toString() ?? '',
      unitType: unitType,
      categorySlug: categorySlug,
      unitLabel: unitLabel,
      displayName: map['displayName']?.toString() ??
          (unitLabel != null ? 'Unit $unitLabel' : 'Available Unit'),
      size: map['size']?.toString(),
      description: map['description']?.toString(),
      status: map['status']?.toString() ?? 'unavailable',
      isRentable: map['isRentable'] == true,
      monthlyRate: (map['monthlyRate'] as num?)?.toDouble(),
    );
  }

  static String _toSlug(String raw) {
    return raw
        .toLowerCase()
        .trim()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }
}

class _UnitTypeGroup {
  final String key;
  final String unitType;
  final String categorySlug;
  final String? sizeLabel;
  final List<_PublicUnitView> units = <_PublicUnitView>[];

  _UnitTypeGroup({
    required this.key,
    required this.unitType,
    required this.categorySlug,
    required this.sizeLabel,
  });

  void addUnit(_PublicUnitView unit) {
    units.add(unit);
  }

  List<_PublicUnitView> get availableUnits => units
      .where((u) =>
          (u.status == 'available' || u.status == 'reserved') && u.isRentable)
      .toList();

  double? get lowestRate {
    final rates =
        availableUnits.map((u) => u.monthlyRate).whereType<double>().toList();
    if (rates.isEmpty) return null;
    rates.sort();
    return rates.first;
  }

  String? get description {
    for (final unit in availableUnits) {
      if (unit.description != null && unit.description!.trim().isNotEmpty) {
        return unit.description;
      }
    }
    return null;
  }

  String get title {
    final readableType = unitType
        .replaceAllMapped(RegExp(r'([A-Z])'), (m) => ' ${m.group(1)}')
        .trim();
    if (sizeLabel == null ||
        sizeLabel!.isEmpty ||
        sizeLabel == 'Size not specified') {
      return readableType;
    }
    return '$sizeLabel • $readableType';
  }

  String get sortLabel => '${unitType.toLowerCase()}|${sizeLabel ?? ''}';
}

class _ReservationDialog extends StatefulWidget {
  final String title;
  final String? priceText;

  const _ReservationDialog({
    required this.title,
    this.priceText,
  });

  @override
  State<_ReservationDialog> createState() => _ReservationDialogState();
}

enum _AssignChoice { autoAssign, chooseSpecific }

class _ReservationDialogState extends State<_ReservationDialog> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  DateTime? _moveInDate;

  @override
  void dispose() {
    _emailController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _pickMoveInDate() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: _moveInDate ?? DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (selected == null) return;
    setState(() => _moveInDate = selected);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.priceText != null) ...[
                Text(
                  widget.priceText!,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 18),
                ),
                const SizedBox(height: 16),
              ],
              TextFormField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.email),
                ),
                validator: (value) {
                  final email = value?.trim() ?? '';
                  if (email.isEmpty) return 'Email is required';
                  if (!email.contains('@')) return 'Enter a valid email';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Full Name',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.person),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.phone),
                ),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: _pickMoveInDate,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Preferred Move-In Date',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.calendar_today),
                  ),
                  child: Text(
                    _moveInDate == null
                        ? 'Select date'
                        : DateFormat.yMMMd().format(_moveInDate!),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (_formKey.currentState?.validate() != true) return;
            Navigator.of(context).pop(<String, String?>{
              'email': _emailController.text.trim(),
              'name': _nameController.text.trim().isEmpty
                  ? null
                  : _nameController.text.trim(),
              'phone': _phoneController.text.trim().isEmpty
                  ? null
                  : _phoneController.text.trim(),
              'moveInDate': _moveInDate?.toIso8601String(),
            });
          },
          child: const Text('Continue'),
        ),
      ],
    );
  }
}
