import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/providers/unit_provider.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// Unit number field plus optional dropdown of existing facility units (same UX as create tenant).
class TenantFacilityUnitPicker extends ConsumerStatefulWidget {
  const TenantFacilityUnitPicker({
    super.key,
    required this.facilityId,
    required this.unitNumberController,
    required this.monthlyRateController,
    this.forTenantId,
    this.unitFieldRequired = true,
  });

  final String facilityId;
  final TextEditingController unitNumberController;
  final TextEditingController monthlyRateController;

  /// When set, pre-selects the unit linked to this tenant (or matches unit number).
  final String? forTenantId;

  final bool unitFieldRequired;

  @override
  ConsumerState<TenantFacilityUnitPicker> createState() =>
      _TenantFacilityUnitPickerState();
}

class _TenantFacilityUnitPickerState extends ConsumerState<TenantFacilityUnitPicker> {
  String? _selectedUnitId;
  bool _scheduledInitialSelection = false;

  String? _resolveSelectedUnitId(List<UnitModel> units) {
    if (widget.forTenantId != null) {
      for (final u in units) {
        if (u.tenantId == widget.forTenantId) return u.id;
      }
    }
    final n = widget.unitNumberController.text.trim();
    if (n.isEmpty) return null;
    final matches =
        units.where((u) => u.unitNumber.trim() == n).toList();
    if (matches.isEmpty) return null;
    if (matches.length == 1) return matches.first.id;
    if (widget.forTenantId != null) {
      for (final u in matches) {
        if (u.tenantId == widget.forTenantId) return u.id;
      }
    }
    return matches.first.id;
  }

  void _scheduleInitialSelection(List<UnitModel> units) {
    if (_scheduledInitialSelection) return;
    _scheduledInitialSelection = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final id = _resolveSelectedUnitId(units);
      setState(() => _selectedUnitId = id);
    });
  }

  Widget _manualField({bool showCreateHint = true}) {
    return TextFormField(
      controller: widget.unitNumberController,
      decoration: InputDecoration(
        labelText: widget.unitFieldRequired ? 'Unit Number *' : 'Unit Number',
        hintText: 'e.g., A101, 205, Storage-12',
        border: const OutlineInputBorder(),
        prefixIcon: const Icon(Icons.home),
        helperText: showCreateHint
            ? 'If the unit does not exist yet, it will be created when you save'
            : null,
      ),
      onChanged: (_) {
        if (_selectedUnitId != null) {
          setState(() => _selectedUnitId = null);
        }
      },
      validator: widget.unitFieldRequired
          ? (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Please enter a unit number';
              }
              return null;
            }
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.facilityId.isEmpty) {
      return _manualField();
    }

    final unitsAsync = ref.watch(facilityUnitsProvider(widget.facilityId));
    return unitsAsync.when(
      data: (units) {
        _scheduleInitialSelection(units);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _manualField(),
            const SizedBox(height: 8),
            if (units.isNotEmpty)
              DropdownButtonFormField<String>(
                value: _selectedUnitId,
                decoration: const InputDecoration(
                  labelText: 'Select from Existing Units (Optional)',
                  hintText: 'Choose a unit to fill number and rate',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.map),
                  helperText:
                      'Use this after bulk-importing units, or type a number above',
                ),
                items: [
                  const DropdownMenuItem<String>(
                    value: null,
                    child: Text(
                        'Enter unit number manually (will create if needed)'),
                  ),
                  ...units.map((unit) {
                    final statusIcon = unit.status == UnitStatus.available
                        ? Icons.check_circle
                        : unit.status == UnitStatus.occupied
                            ? Icons.person
                            : Icons.block;
                    final statusColor = unit.status == UnitStatus.available
                        ? AppTheme.success
                        : unit.status == UnitStatus.occupied
                            ? AppTheme.warning
                            : AppTheme.textTertiary;
                    return DropdownMenuItem<String>(
                      value: unit.id,
                      child: Row(
                        children: [
                          Icon(statusIcon, size: 16, color: statusColor),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Unit ${unit.unitNumber} - \$${unit.monthlyRate.toStringAsFixed(2)}/mo',
                              style: TextStyle(
                                color: unit.status == UnitStatus.occupied
                                    ? AppTheme.textTertiary
                                    : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
                onChanged: (value) {
                  setState(() {
                    _selectedUnitId = value;
                    if (value != null) {
                      final unit = units.firstWhere((u) => u.id == value);
                      widget.unitNumberController.text = unit.unitNumber;
                      widget.monthlyRateController.text =
                          unit.monthlyRate.toStringAsFixed(2);
                    }
                  });
                },
              ),
          ],
        );
      },
      loading: () => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _manualField(showCreateHint: false),
          const SizedBox(height: 8),
          const LinearProgressIndicator(minHeight: 2),
        ],
      ),
      error: (_, __) => _manualField(),
    );
  }
}
