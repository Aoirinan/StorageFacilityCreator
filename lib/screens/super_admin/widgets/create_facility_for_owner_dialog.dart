import 'package:flutter/material.dart';

import 'package:sfcapp/services/super_admin_data_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// Collects the handful of details needed to stand up a facility for an owner.
///
/// Only the name is required. Everything else has a working default, because
/// the point is to get an owner's facility into existence so their units and
/// tenants can go in; the owner can correct the details later in settings.
class CreateFacilityForOwnerDialog extends StatefulWidget {
  final String ownerUid;
  final String ownerEmail;

  const CreateFacilityForOwnerDialog({
    super.key,
    required this.ownerUid,
    required this.ownerEmail,
  });

  @override
  State<CreateFacilityForOwnerDialog> createState() =>
      _CreateFacilityForOwnerDialogState();
}

class _CreateFacilityForOwnerDialogState
    extends State<CreateFacilityForOwnerDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _phone = TextEditingController();
  final _totalUnits = TextEditingController();
  final _graceDays = TextEditingController(text: '5');
  final _lateFee = TextEditingController(text: '25');
  String _timeZone = 'America/Chicago';
  bool _saving = false;
  String? _error;

  static const _timeZones = [
    'America/New_York',
    'America/Chicago',
    'America/Denver',
    'America/Phoenix',
    'America/Los_Angeles',
    'America/Anchorage',
    'Pacific/Honolulu',
  ];

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _phone.dispose();
    _totalUnits.dispose();
    _graceDays.dispose();
    _lateFee.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final facilityId = await SuperAdminDataService.createFacilityForOwner(
        ownerUid: widget.ownerUid,
        name: _name.text,
        address: _address.text,
        phone: _phone.text,
        email: widget.ownerEmail,
        timeZone: _timeZone,
        totalUnits: int.tryParse(_totalUnits.text.trim()),
        gracePeriodDays: int.tryParse(_graceDays.text.trim()),
        lateFeeAmount: num.tryParse(_lateFee.text.trim()),
      );
      if (!mounted) return;
      Navigator.pop(context, (id: facilityId, name: _name.text.trim()));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create a facility for this owner'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'The facility will belong to ${widget.ownerEmail}, not to you. '
                  'You are recorded as having set it up.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _name,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Facility name *',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'A name is required'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _address,
                  decoration: const InputDecoration(
                    labelText: 'Address',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phone,
                  decoration: const InputDecoration(
                    labelText: 'Phone',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _timeZone,
                  decoration: const InputDecoration(
                    labelText: 'Time zone',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: _timeZones
                      .map((tz) =>
                          DropdownMenuItem(value: tz, child: Text(tz)))
                      .toList(),
                  onChanged: (v) => setState(() => _timeZone = v ?? _timeZone),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _totalUnits,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Unit capacity',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _graceDays,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Grace days',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _lateFee,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Late fee',
                          border: OutlineInputBorder(),
                          isDense: true,
                          prefixText: '\$',
                        ),
                      ),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: AppTheme.error)),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Create facility'),
        ),
      ],
    );
  }
}
