import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/constants/location_options.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/providers/unit_provider.dart';
import 'package:sfcapp/services/modern_navigation_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/widgets/keyboard_scrollable.dart';
import 'package:sfcapp/widgets/modern_page_wrapper.dart';
import 'package:sfcapp/widgets/tenant_facility_unit_picker.dart';

class TenantEditScreen extends ConsumerStatefulWidget {
  final TenantModel tenant;
  final String? facilityIdOverride;

  const TenantEditScreen({
    super.key,
    required this.tenant,
    this.facilityIdOverride,
  });

  @override
  ConsumerState<TenantEditScreen> createState() => _TenantEditScreenState();
}

class _TenantEditScreenState extends ConsumerState<TenantEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _unitController = TextEditingController();
  final _rateController = TextEditingController();
  final _notesController = TextEditingController();
  final _idNumberController = TextEditingController();
  final _idStateController = TextEditingController();
  final _idCountryController = TextEditingController();
  final _portalAccessCodeController = TextEditingController();
  final _portalWelcomeController = TextEditingController();
  DateTime? _idIssuedDate;
  DateTime? _idExpirationDate;
  String _selectedIdType = 'none';
  String? _selectedIdState;
  String? _selectedIdCountry;
  late final List<_ContactFieldControllers> _contactControllers;
  late final List<_VehicleFieldControllers> _vehicleControllers;
  
  bool _isLoading = false;
  bool _isActive = true;
  bool _isOnDNR = false;
  String? _errorMessage;
  bool _portalEnabled = false;
  DateTime? _portalLastAccessAt;
  int _portalVisitCount = 0;
  bool _smsConsent = false; // SMS consent checkbox state

  final Random _random = Random.secure();
  late final String _facilityId;

  @override
  void initState() {
    super.initState();
    _facilityId = (widget.tenant.facilityId.isNotEmpty
            ? widget.tenant.facilityId
            : widget.facilityIdOverride) ??
        '';
    _initializeFields();
  }

  bool get _hasFacilityContext => _facilityId.isNotEmpty;

  void _initializeFields() {
    _nameController.text = widget.tenant.name;
    _emailController.text = widget.tenant.email;
    _phoneController.text = widget.tenant.phone;
    _unitController.text = widget.tenant.unitNumber;
    _rateController.text = widget.tenant.monthlyRate.toString();
    _notesController.text = widget.tenant.notes ?? '';
    _isActive = widget.tenant.isActive;
    _isOnDNR = widget.tenant.isOnDNR;
    _portalEnabled = widget.tenant.portalEnabled;
    _portalAccessCodeController.text = widget.tenant.portalAccessCode ?? '';
    _portalWelcomeController.text = widget.tenant.portalWelcomeMessage ?? '';
    _portalLastAccessAt = widget.tenant.portalLastAccessAt;
    _portalVisitCount = widget.tenant.portalVisitCount;
    _smsConsent = widget.tenant.smsOptInDate != null && !widget.tenant.smsOptOut;
    _idNumberController.text = widget.tenant.governmentIdNumber ?? '';
    _idStateController.text = widget.tenant.governmentIdState ?? '';
    _selectedIdState = widget.tenant.governmentIdState;
    _selectedIdCountry = widget.tenant.governmentIdCountry?.isNotEmpty == true
        ? widget.tenant.governmentIdCountry
        : 'United States';
    _idCountryController.text = _selectedIdCountry ?? 'United States';
    final rawIdType = widget.tenant.governmentIdType?.trim();
    if (rawIdType == null || rawIdType.isEmpty || rawIdType == 'none') {
      _selectedIdType = 'none';
    } else {
      _selectedIdType = rawIdType;
    }
    _idIssuedDate = widget.tenant.governmentIdIssuedAt;
    _idExpirationDate = widget.tenant.governmentIdExpiresAt;
    _contactControllers = widget.tenant.emergencyContacts.isNotEmpty
        ? widget.tenant.emergencyContacts
            .map((contact) => _ContactFieldControllers(
                  isPrimary: contact.isPrimary,
                  isEmergency: contact.isEmergency,
                  name: contact.name,
                  relationship: contact.relationship,
                  phone: contact.phone,
                  email: contact.email,
                ))
            .toList()
        : [
            _ContactFieldControllers(isPrimary: true),
          ];
    if (_contactControllers.isNotEmpty && !_contactControllers.any((controller) => controller.isPrimary)) {
      _contactControllers.first.isPrimary = true;
    }
    _vehicleControllers = widget.tenant.vehicles.isNotEmpty
        ? widget.tenant.vehicles
            .map((vehicle) => _VehicleFieldControllers(
                  make: vehicle.make,
                  model: vehicle.model,
                  color: vehicle.color,
                  plate: vehicle.licensePlate,
                  state: vehicle.state,
                  notes: vehicle.notes,
                ))
            .toList()
        : [];
  }

  void _addContact() {
    setState(() {
      _contactControllers.add(_ContactFieldControllers());
    });
  }

  void _removeContact(int index) {
    if (_contactControllers.length == 1) return;
    setState(() {
      final removed = _contactControllers.removeAt(index);
      removed.dispose();
    });
  }

  void _setPrimaryContact(int index, bool value) {
    if (!value) {
      // Ensure at least one primary contact remains
      if (_contactControllers.where((controller) => controller.isPrimary).length == 1 &&
          _contactControllers[index].isPrimary) {
        return;
      }
    }

    setState(() {
      for (var i = 0; i < _contactControllers.length; i++) {
        _contactControllers[i].isPrimary = value && i == index;
      }
      if (!_contactControllers.any((controller) => controller.isPrimary)) {
        _contactControllers.first.isPrimary = true;
      }
    });
  }

  void _addVehicle() {
    setState(() {
      _vehicleControllers.add(_VehicleFieldControllers());
    });
  }

  void _removeVehicle(int index) {
    if (index < 0 || index >= _vehicleControllers.length) return;
    setState(() {
      final removed = _vehicleControllers.removeAt(index);
      removed.dispose();
    });
  }

  String _generateAccessCode({int length = 8}) {
    const characters = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    return List.generate(length, (index) => characters[_random.nextInt(characters.length)]).join();
  }

  void _regeneratePortalAccessCode() {
    setState(() {
      _portalAccessCodeController.text = _generateAccessCode();
    });
  }

  Future<void> _copyPortalAccessCode() async {
    final code = _portalAccessCodeController.text.trim();
    if (code.isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Portal access code copied to clipboard'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  String _formatPortalTimestamp(DateTime? value) {
    if (value == null) {
      return 'Never accessed';
    }
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    final year = value.year;
    final hourRaw = value.hour % 12;
    final hour = hourRaw == 0 ? 12 : hourRaw;
    final minute = value.minute.toString().padLeft(2, '0');
    final suffix = value.hour >= 12 ? 'PM' : 'AM';
    return '$month/$day/$year at $hour:$minute $suffix';
  }
 
  Future<void> _pickIssuedDate() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: _idIssuedDate ?? DateTime.now().subtract(const Duration(days: 30)),
      firstDate: DateTime.now().subtract(const Duration(days: 3650)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );

    if (selected != null) {
      setState(() => _idIssuedDate = selected);
    }
  }

  Future<void> _pickExpirationDate() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: _idExpirationDate ?? DateTime.now().add(const Duration(days: 365)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
    );

    if (selected != null) {
      setState(() => _idExpirationDate = selected);
    }
  }

  String _formatDate(DateTime? date) {
    if (date == null) return 'Not set';
    return '${date.month}/${date.day}/${date.year}';
  }

  List<TenantContact> _collectContacts() {
    final contacts = <TenantContact>[];
    for (final entry in _contactControllers) {
      final name = entry.nameController.text.trim();
      final relationship = entry.relationshipController.text.trim();
      final phone = entry.phoneController.text.trim();
      final email = entry.emailController.text.trim();
      if ([name, relationship, phone, email].every((value) => value.isEmpty)) {
        continue;
      }

      final resolvedName = name.isNotEmpty
          ? name
          : (relationship.isNotEmpty
              ? '${relationship[0].toUpperCase()}${relationship.substring(1)} Contact'
              : (phone.isNotEmpty
                  ? phone
                  : (email.isNotEmpty ? email : 'Emergency Contact ${contacts.length + 1}')));

      contacts.add(
        TenantContact(
          name: resolvedName,
          relationship: relationship.isNotEmpty ? relationship : null,
          phone: phone.isNotEmpty ? phone : null,
          email: email.isNotEmpty ? email : null,
          isPrimary: entry.isPrimary,
          isEmergency: entry.isEmergency,
        ),
      );
    }
    if (contacts.isNotEmpty && !contacts.any((contact) => contact.isPrimary)) {
      final first = contacts.first;
      contacts[0] = TenantContact(
        name: first.name,
        relationship: first.relationship,
        phone: first.phone,
        email: first.email,
        isPrimary: true,
        isEmergency: first.isEmergency,
      );
    }
    return contacts;
  }

  List<TenantVehicle> _collectVehicles() {
    final vehicles = <TenantVehicle>[];
    for (final entry in _vehicleControllers) {
      final make = entry.makeController.text.trim();
      final model = entry.modelController.text.trim();
      final color = entry.colorController.text.trim();
      final plate = entry.plateController.text.trim();
      final state = entry.stateController.text.trim();
      final notes = entry.notesController.text.trim();

      if (make.isEmpty && model.isEmpty && plate.isEmpty && notes.isEmpty) {
        continue;
      }

      vehicles.add(
        TenantVehicle(
          make: make.isNotEmpty ? make : 'Vehicle',
          model: model.isNotEmpty ? model : '',
          color: color.isNotEmpty ? color : null,
          licensePlate: plate.isNotEmpty ? plate : null,
          state: state.isNotEmpty ? state : null,
          notes: notes.isNotEmpty ? notes : null,
        ),
      );
    }
    return vehicles;
  }

  Widget _buildIdentificationSection() {
    return Card(
      margin: const EdgeInsets.only(top: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Identification',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _selectedIdType,
              decoration: const InputDecoration(
                labelText: 'ID Type',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.badge_outlined),
              ),
              items: const [
                DropdownMenuItem(value: 'none', child: Text('Not Captured')),
                DropdownMenuItem(value: 'drivers_license', child: Text('Driver\'s License')),
                DropdownMenuItem(value: 'state_id', child: Text('State ID')),
                DropdownMenuItem(value: 'passport', child: Text('Passport')),
                DropdownMenuItem(value: 'military_id', child: Text('Military ID')),
                DropdownMenuItem(value: 'other', child: Text('Other')),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _selectedIdType = value);
                }
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _idNumberController,
              decoration: const InputDecoration(
                labelText: 'ID Number',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.confirmation_number_outlined),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _selectedIdState?.isNotEmpty == true ? _selectedIdState : null,
              decoration: const InputDecoration(
                labelText: 'Issuing State',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.flag_outlined),
              ),
              items: [
                const DropdownMenuItem<String>(
                  value: '',
                  child: Text('Not Selected'),
                ),
                ...kUsStateMap.entries.map(
                  (entry) => DropdownMenuItem<String>(
                    value: entry.key,
                    child: Text('${entry.key} — ${entry.value}'),
                  ),
                ),
              ],
              onChanged: _isLoading
                  ? null
                  : (value) {
                      setState(() {
                        final normalized = value == null || value.isEmpty ? null : value;
                        _selectedIdState = normalized;
                        _idStateController.text = normalized ?? '';
                      });
                    },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _selectedIdCountry?.isNotEmpty == true ? _selectedIdCountry : null,
              decoration: const InputDecoration(
                labelText: 'Issuing Country',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.public_outlined),
              ),
              items: [
                const DropdownMenuItem<String>(
                  value: '',
                  child: Text('Not Selected'),
                ),
                ...kDefaultCountryPriority.map(
                  (country) => DropdownMenuItem<String>(
                    value: country,
                    child: Text(country),
                  ),
                ),
                ...kCountryList
                    .where((country) => !kDefaultCountryPriority.contains(country))
                    .map(
                      (country) => DropdownMenuItem<String>(
                        value: country,
                        child: Text(country),
                      ),
                    ),
              ],
              onChanged: _isLoading
                  ? null
                  : (value) {
                      setState(() {
                      final normalized = value == null || value.isEmpty ? null : value;
                      _selectedIdCountry = normalized;
                      _idCountryController.text = normalized ?? '';
                      });
                    },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isLoading ? null : _pickIssuedDate,
                    icon: const Icon(Icons.calendar_month),
                    label: Text('Issued: ${_formatDate(_idIssuedDate)}'),
                  ),
                ),
                const SizedBox(width: 12),
                if (_idIssuedDate != null)
                  IconButton(
                    tooltip: 'Clear issued date',
                    icon: const Icon(Icons.clear),
                    onPressed: _isLoading
                        ? null
                        : () {
                            setState(() => _idIssuedDate = null);
                          },
                  ),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isLoading ? null : _pickExpirationDate,
                    icon: const Icon(Icons.event),
                    label: Text('Expires: ${_formatDate(_idExpirationDate)}'),
                  ),
                ),
                const SizedBox(width: 12),
                if (_idExpirationDate != null)
                  IconButton(
                    tooltip: 'Clear expiration date',
                    icon: const Icon(Icons.clear),
                    onPressed: _isLoading
                        ? null
                        : () {
                            setState(() => _idExpirationDate = null);
                          },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContactCard(int index, _ContactFieldControllers controllers) {
    final title = controllers.isPrimary ? 'Primary Contact' : 'Contact ${index + 1}';
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (_contactControllers.length > 1)
                  IconButton(
                    tooltip: 'Remove contact',
                    icon: Icon(Icons.delete_outline, color: AppTheme.error),
                    onPressed: _isLoading ? null : () => _removeContact(index),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: controllers.nameController,
              decoration: const InputDecoration(
                labelText: 'Full Name',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: controllers.relationshipController,
              decoration: const InputDecoration(
                labelText: 'Relationship',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.group_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: controllers.phoneController,
              decoration: const InputDecoration(
                labelText: 'Phone Number',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.phone_outlined),
              ),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: controllers.emailController,
              decoration: const InputDecoration(
                labelText: 'Email',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.email_outlined),
              ),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              title: const Text('Primary Contact'),
              subtitle: const Text('Use this contact first for notifications'),
              value: controllers.isPrimary,
              onChanged: _isLoading ? null : (value) => _setPrimaryContact(index, value),
            ),
            SwitchListTile(
              title: const Text('Emergency Contact'),
              subtitle: const Text('Include in emergency notifications'),
              value: controllers.isEmergency,
              onChanged: _isLoading
                  ? null
                  : (value) {
                      setState(() => controllers.isEmergency = value);
                    },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContactsSection() {
    return Card(
      margin: const EdgeInsets.only(top: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Contacts',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _isLoading ? null : _addContact,
                  icon: const Icon(Icons.add),
                  label: const Text('Add Contact'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Maintain emergency and alternate contacts for this tenant.',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
            ...List.generate(
              _contactControllers.length,
              (index) => _buildContactCard(index, _contactControllers[index]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVehicleCard(int index, _VehicleFieldControllers controllers) {
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Vehicle ${index + 1}',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Remove vehicle',
                  icon: Icon(Icons.delete_outline, color: AppTheme.error),
                  onPressed: _isLoading ? null : () => _removeVehicle(index),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: controllers.makeController,
              decoration: const InputDecoration(
                labelText: 'Make',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.directions_car_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: controllers.modelController,
              decoration: const InputDecoration(
                labelText: 'Model',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.directions_car),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: controllers.colorController,
              decoration: const InputDecoration(
                labelText: 'Color',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.color_lens_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: controllers.plateController,
              decoration: const InputDecoration(
                labelText: 'License Plate',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.local_parking_outlined),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: controllers.stateController.text.isNotEmpty ? controllers.stateController.text : null,
              decoration: const InputDecoration(
                labelText: 'Plate State/Province',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.map_outlined),
              ),
              items: [
                const DropdownMenuItem<String>(
                  value: '',
                  child: Text('Not Selected'),
                ),
                ...kUsStateMap.entries.map(
                  (entry) => DropdownMenuItem<String>(
                    value: entry.key,
                    child: Text('${entry.key} — ${entry.value}'),
                  ),
                ),
              ],
              onChanged: _isLoading ? null : (value) => controllers.stateController.text = value ?? '',
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: controllers.notesController,
              decoration: const InputDecoration(
                labelText: 'Vehicle Notes',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.note_alt_outlined),
              ),
              maxLines: 2,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVehiclesSection() {
    return Card(
      margin: const EdgeInsets.only(top: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Vehicles',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _isLoading ? null : _addVehicle,
                  icon: const Icon(Icons.add_road),
                  label: const Text('Add Vehicle'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Keep vehicle information current for gate access and security.',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
            if (_vehicleControllers.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: OutlinedButton.icon(
                  onPressed: _isLoading ? null : _addVehicle,
                  icon: const Icon(Icons.add_circle_outline),
                  label: const Text('Add First Vehicle'),
                ),
              )
            else
              ...List.generate(
                _vehicleControllers.length,
                (index) => _buildVehicleCard(index, _vehicleControllers[index]),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPortalAccessSection() {
    return Card(
      margin: const EdgeInsets.only(top: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Tenant Portal Access',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Switch.adaptive(
                  value: _portalEnabled,
                  onChanged: _isLoading
                      ? null
                      : (value) {
                          setState(() {
                            _portalEnabled = value;
                            if (value && _portalAccessCodeController.text.trim().isEmpty) {
                              _portalAccessCodeController.text = _generateAccessCode();
                            }
                          });
                        },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _portalEnabled
                  ? 'Tenants can view their unit, balance, and payment history with this access code.'
                  : 'Disable portal access to revoke the tenant\'s self-service login code.',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
            if (_portalEnabled) ...[
              const SizedBox(height: 16),
              TextFormField(
                controller: _portalAccessCodeController,
                decoration: InputDecoration(
                  labelText: 'Portal Access Code',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.vpn_key_outlined),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Copy',
                        icon: const Icon(Icons.copy),
                        onPressed: _isLoading ? null : _copyPortalAccessCode,
                      ),
                      IconButton(
                        tooltip: 'Regenerate',
                        icon: const Icon(Icons.refresh),
                        onPressed: _isLoading ? null : _regeneratePortalAccessCode,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _portalWelcomeController,
                decoration: const InputDecoration(
                  labelText: 'Welcome Message (optional)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.message_outlined),
                  hintText: 'Shown at the top of the tenant portal dashboard.',
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  Chip(
                    avatar: const Icon(Icons.access_time, size: 16),
                    label: Text(_formatPortalTimestamp(_portalLastAccessAt)),
                  ),
                  Chip(
                    avatar: const Icon(Icons.analytics_outlined, size: 16),
                    label: Text('Visits: $_portalVisitCount'),
                  ),
                ],
              ),
            ]
            else if ((_portalAccessCodeController.text.isNotEmpty || widget.tenant.portalAccessCode != null)) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.warning.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Portal access is currently disabled. Enable it to share a new login code with the tenant.',
                  style: TextStyle(color: AppTheme.textPrimary),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
 
  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _unitController.dispose();
    _rateController.dispose();
    _notesController.dispose();
    _idNumberController.dispose();
    _idStateController.dispose();
    _idCountryController.dispose();
    _portalAccessCodeController.dispose();
    _portalWelcomeController.dispose();
    for (final contact in _contactControllers) {
      contact.dispose();
    }
    for (final vehicle in _vehicleControllers) {
      vehicle.dispose();
    }
    super.dispose();
  }

  Future<void> _updateTenant() async {
    if (!_formKey.currentState!.validate()) return;
    
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final idNumber = _idNumberController.text.trim();
    final idState = _idStateController.text.trim();
    final idCountry = _idCountryController.text.trim();
    final idTypeForUpdate = (_selectedIdType.isEmpty || _selectedIdType == 'none') ? '' : _selectedIdType;
    final contacts = _collectContacts();
    final vehicles = _collectVehicles();
    final clearIssuedDate = _idIssuedDate == null && widget.tenant.governmentIdIssuedAt != null;
    final clearExpirationDate = _idExpirationDate == null && widget.tenant.governmentIdExpiresAt != null;
    if (_portalEnabled && _portalAccessCodeController.text.trim().isEmpty) {
      _portalAccessCodeController.text = _generateAccessCode();
    }
    final trimmedPortalCode = _portalAccessCodeController.text.trim();
    final portalAccessCode = _portalEnabled && trimmedPortalCode.isNotEmpty ? trimmedPortalCode : null;
    final shouldClearPortalCode = !_portalEnabled && (widget.tenant.portalAccessCode?.isNotEmpty ?? false);
    final trimmedWelcome = _portalWelcomeController.text.trim();
    final portalWelcomeForUpdate = _portalEnabled
        ? (trimmedWelcome.isNotEmpty ? trimmedWelcome : null)
        : '';
    final resetPortalStats = portalAccessCode != null && portalAccessCode != widget.tenant.portalAccessCode;

    try {
      if (!_hasFacilityContext) {
        throw Exception('Missing facility context for this tenant record.');
      }

      await ref.read(tenantOperationsProvider.notifier).updateTenant(
        facilityId: _facilityId,
        tenantId: widget.tenant.id,
        name: _nameController.text.trim(),
        email: _emailController.text.trim(),
        phone: _phoneController.text.trim(),
        unitNumber: _unitController.text.trim(),
        monthlyRate: double.parse(_rateController.text.trim()),
        notes: _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
        isActive: _isActive,
        governmentIdType: idTypeForUpdate,
        governmentIdNumber: idNumber,
        governmentIdState: idState,
        governmentIdCountry: idCountry,
        governmentIdIssuedAt: _idIssuedDate,
        governmentIdExpiresAt: _idExpirationDate,
        clearGovernmentIdIssuedAt: clearIssuedDate,
        clearGovernmentIdExpiresAt: clearExpirationDate,
        emergencyContacts: contacts,
        vehicles: vehicles,
        portalEnabled: _portalEnabled,
        smsOptInDate: _smsConsent && !widget.tenant.smsOptOut ? DateTime.now() : null,
        portalAccessCode: portalAccessCode,
        clearPortalAccessCode: shouldClearPortalCode,
        portalWelcomeMessage: portalWelcomeForUpdate,
        portalLastAccessAt: _portalLastAccessAt,
        resetPortalStats: resetPortalStats,
      );

      if (mounted) {
        ref.invalidate(facilityTenantsProvider(_facilityId));
        ref.invalidate(facilityUnitsProvider(_facilityId));
        ref.invalidate(unitsForFacilityProvider(_facilityId));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${widget.tenant.name} updated successfully!'),
            backgroundColor: AppTheme.success,
            duration: const Duration(seconds: 2),
          ),
        );

        // Navigate back
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
        });
        final friendlyMessage = _errorMessage?.replaceFirst(RegExp(r'^Exception:\\s*'), '') ??
            'Unable to update tenant. Please try again.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(friendlyMessage),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: KeyboardScrollable(
            child: SingleChildScrollView(
              child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!_hasFacilityContext)
                  Card(
                    color: AppTheme.warning.withOpacity(0.1),
                    margin: const EdgeInsets.only(bottom: 16),
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.warning_amber_rounded, color: AppTheme.warning),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Facility information is missing for this tenant. Saving is disabled until the record is associated with a facility. Return to Client Management, select the correct facility, and retry editing.',
                              style: TextStyle(
                                color: AppTheme.warning,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                // Basic Information
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Basic Information',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 16),
                        
                        // Name
                        TextFormField(
                          controller: _nameController,
                          decoration: const InputDecoration(
                            labelText: 'Full Name *',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.person),
                          ),
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Please enter the tenant\'s name';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),
                        
                        // Email
                        TextFormField(
                          controller: _emailController,
                          decoration: const InputDecoration(
                            labelText: 'Email *',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.email),
                          ),
                          keyboardType: TextInputType.emailAddress,
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Please enter an email address';
                            }
                            if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(value)) {
                              return 'Please enter a valid email address';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),
                        
                        // Phone
                        TextFormField(
                          controller: _phoneController,
                          decoration: const InputDecoration(
                            labelText: 'Phone Number *',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.phone),
                          ),
                          keyboardType: TextInputType.phone,
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Please enter a phone number';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),
                        
                        // SMS Consent Checkbox
                        if (_hasFacilityContext) ...[
                          Consumer(
                            builder: (context, ref, child) {
                              final facilityAsync = ref.watch(facilityProvider(_facilityId));
                              final facilityName = facilityAsync.value?.name ?? 'this facility';
                              
                              return Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: AppTheme.backgroundSecondary,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: AppTheme.borderLight),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Checkbox(
                                          value: _smsConsent && !widget.tenant.smsOptOut,
                                          onChanged: widget.tenant.smsOptOut
                                              ? null
                                              : (value) {
                                                  setState(() {
                                                    _smsConsent = value ?? false;
                                                  });
                                                },
                                        ),
                                        Expanded(
                                          child: GestureDetector(
                                            onTap: widget.tenant.smsOptOut
                                                ? null
                                                : () {
                                                    setState(() {
                                                      _smsConsent = !_smsConsent;
                                                    });
                                                  },
                                            child: Padding(
                                              padding: const EdgeInsets.only(top: 12),
                                              child: widget.tenant.smsOptOut
                                                  ? Text(
                                                      'This tenant has opted out of SMS messaging. They cannot receive SMS messages.',
                                                      style: TextStyle(
                                                        fontSize: 13,
                                                        color: AppTheme.error,
                                                        fontWeight: FontWeight.w500,
                                                      ),
                                                    )
                                                  : RichText(
                                                      text: TextSpan(
                                                        style: const TextStyle(
                                                          fontSize: 13,
                                                          color: AppTheme.textPrimary,
                                                          height: 1.4,
                                                        ),
                                                        children: [
                                                          TextSpan(
                                                            text: 'I agree to receive SMS reminders and account notifications from $facilityName. ',
                                                            style: const TextStyle(fontWeight: FontWeight.w500),
                                                          ),
                                                          const TextSpan(
                                                            text: 'Reply STOP to opt out, HELP for help. Message frequency varies. Msg & data rates may apply. ',
                                                          ),
                                                          WidgetSpan(
                                                            child: GestureDetector(
                                                              onTap: () {
                                                                context.go('/sms-policy');
                                                              },
                                                              child: const Text(
                                                                'See SMS Policy',
                                                                style: TextStyle(
                                                                  color: AppTheme.primaryBlue,
                                                                  decoration: TextDecoration.underline,
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 16),
                        ],
                        
                        if (_hasFacilityContext)
                          TenantFacilityUnitPicker(
                            key: ValueKey('${_facilityId}_${widget.tenant.id}'),
                            facilityId: _facilityId,
                            unitNumberController: _unitController,
                            monthlyRateController: _rateController,
                            forTenantId: widget.tenant.id,
                          )
                        else
                          TextFormField(
                            controller: _unitController,
                            decoration: const InputDecoration(
                              labelText: 'Unit Number *',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.home),
                            ),
                            validator: (value) {
                              if (value == null || value.trim().isEmpty) {
                                return 'Please enter a unit number';
                              }
                              return null;
                            },
                          ),
                        const SizedBox(height: 16),
                        
                        // Monthly Rate
                        TextFormField(
                          controller: _rateController,
                          decoration: const InputDecoration(
                            labelText: 'Monthly Rate *',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.attach_money),
                          ),
                          keyboardType: TextInputType.number,
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Please enter the monthly rate';
                            }
                            final rate = double.tryParse(value);
                            if (rate == null || rate <= 0) {
                              return 'Please enter a valid monthly rate';
                            }
                            return null;
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                
                const SizedBox(height: 16),

                _buildIdentificationSection(),
                _buildContactsSection(),
                _buildVehiclesSection(),
                _buildPortalAccessSection(),

                const SizedBox(height: 16),

                // Status and Settings
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Status & Settings',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 16),
                        
                        // Active Status
                        SwitchListTile(
                          title: const Text('Active Tenant'),
                          subtitle: const Text('Tenant is currently active'),
                          value: _isActive,
                          onChanged: _isLoading ? null : (value) {
                            setState(() {
                              _isActive = value;
                            });
                          },
                          secondary: Icon(
                            _isActive ? Icons.check_circle : Icons.cancel,
                            color: _isActive ? AppTheme.success : AppTheme.error,
                          ),
                        ),
                        
                        // DNR Status
                        SwitchListTile(
                          title: const Text('Do Not Rent (DNR)'),
                          subtitle: const Text('Add to Do Not Rent list'),
                          value: _isOnDNR,
                          onChanged: _isLoading ? null : (value) {
                            setState(() {
                              _isOnDNR = value;
                            });
                          },
                          secondary: Icon(
                            _isOnDNR ? Icons.block : Icons.person,
                            color: _isOnDNR ? AppTheme.error : AppTheme.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                
                const SizedBox(height: 16),
                
                // Notes
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Notes',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _notesController,
                          decoration: const InputDecoration(
                            labelText: 'Additional Notes',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.note),
                            hintText: 'Any additional information about this tenant...',
                          ),
                          maxLines: 3,
                        ),
                      ],
                    ),
                  ),
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
                
                // Action Buttons
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _updateTenant,
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
                                  Text('Saving...'),
                                ],
                              )
                            : const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.save),
                                  SizedBox(width: 8),
                                  Text('Save Changes'),
                                ],
                              ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      );
  }
}

class _ContactFieldControllers {
  final TextEditingController nameController;
  final TextEditingController relationshipController;
  final TextEditingController phoneController;
  final TextEditingController emailController;
  bool isPrimary;
  bool isEmergency;

  _ContactFieldControllers({
    String? name,
    String? relationship,
    String? phone,
    String? email,
    this.isPrimary = false,
    this.isEmergency = true,
  })  : nameController = TextEditingController(text: name ?? ''),
        relationshipController = TextEditingController(text: relationship ?? ''),
        phoneController = TextEditingController(text: phone ?? ''),
        emailController = TextEditingController(text: email ?? '');

  void dispose() {
    nameController.dispose();
    relationshipController.dispose();
    phoneController.dispose();
    emailController.dispose();
  }
}

class _VehicleFieldControllers {
  final TextEditingController makeController;
  final TextEditingController modelController;
  final TextEditingController colorController;
  final TextEditingController plateController;
  final TextEditingController stateController;
  final TextEditingController notesController;

  _VehicleFieldControllers({
    String? make,
    String? model,
    String? color,
    String? plate,
    String? state,
    String? notes,
  })  : makeController = TextEditingController(text: make ?? ''),
        modelController = TextEditingController(text: model ?? ''),
        colorController = TextEditingController(text: color ?? ''),
        plateController = TextEditingController(text: plate ?? ''),
        stateController = TextEditingController(text: state ?? ''),
        notesController = TextEditingController(text: notes ?? '');

  void dispose() {
    makeController.dispose();
    modelController.dispose();
    colorController.dispose();
    plateController.dispose();
    stateController.dispose();
    notesController.dispose();
  }
}
