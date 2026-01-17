import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/constants/location_options.dart';
import 'package:sfcapp/models/dnr_model.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/lead_source_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/providers/unit_provider.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/services/audit_service.dart';
import 'package:sfcapp/services/dnr_service.dart';
import 'package:sfcapp/services/email_service.dart';
import 'package:sfcapp/services/email_template_service.dart';
import 'package:sfcapp/services/facility_service.dart';
import 'package:sfcapp/services/gate_access_service.dart';
import 'package:sfcapp/services/modern_navigation_service.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/utils/error_message_helper.dart';
import 'package:sfcapp/widgets/keyboard_scrollable.dart';
import 'package:sfcapp/widgets/modern_page_wrapper.dart';

class TenantCreationScreen extends ConsumerStatefulWidget {
  final List<FacilityModel> facilities;
  final String selectedFacilityId;

  const TenantCreationScreen({
    super.key,
    required this.facilities,
    required this.selectedFacilityId,
  });

  @override
  ConsumerState<TenantCreationScreen> createState() => _TenantCreationScreenState();
}

class _TenantCreationScreenState extends ConsumerState<TenantCreationScreen> {
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
  
  String _selectedFacilityId = '';
  String? _selectedUnitId; // Track selected unit from dropdown
  String _selectedIdType = 'none';
  String? _selectedIdState;
  String? _selectedIdCountry;
  String? _selectedLeadSource; // Lead source (optional)
  DateTime? _idIssuedDate;
  DateTime? _idExpirationDate;
  bool _isLoading = false;
  String? _errorMessage;
  bool _portalEnabled = false;
  bool _dnrOverride = false;
  List<DNRModel>? _dnrMatches;

  final Random _random = Random.secure();

  late final List<_ContactFieldControllers> _contactControllers;
  late final List<_VehicleFieldControllers> _vehicleControllers;

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

  void _ensurePortalAccessCode() {
    if (_portalAccessCodeController.text.trim().isEmpty) {
      _portalAccessCodeController.text = _generateAccessCode();
    }
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

  Future<void> _sendWelcomeEmailWithAccessCodes({
    required String tenantId,
    required String tenantName,
    required String tenantEmail,
    required String facilityId,
    String? unitNumber,
    String? portalAccessCode,
    String? welcomeMessage,
  }) async {
    try {
      if (kDebugMode) {
        print('📧 Preparing to send welcome email to: $tenantEmail');
      }

      // Get facility information
      final facility = await FacilityService.getFacility(facilityId);
      if (facility == null) {
        if (kDebugMode) {
          print('⚠️ Facility not found: $facilityId');
        }
        return;
      }

      // Get gate access code if it exists
      String? gateAccessCode;
      try {
        gateAccessCode = await GateAccessService.getGateAccessCodeForTenant(
          facilityId: facilityId,
          tenantId: tenantId,
        );
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ Could not fetch gate access code: $e');
        }
        // Continue without gate code
      }

      // Only send email if we have at least one access code or portal is enabled
      if ((portalAccessCode == null || portalAccessCode.isEmpty) && gateAccessCode == null) {
        if (kDebugMode) {
          print('ℹ️ No access codes to send, skipping email');
        }
        return;
      }

      // Generate email HTML
      final htmlContent = EmailTemplateService.generateWelcomeEmailWithAccessCodes(
        facilityName: facility.name,
        tenantName: tenantName,
        unitNumber: unitNumber?.isNotEmpty == true ? unitNumber : null,
        portalAccessCode: portalAccessCode?.isNotEmpty == true ? portalAccessCode : null,
        gateAccessCode: gateAccessCode,
        welcomeMessage: welcomeMessage?.isNotEmpty == true ? welcomeMessage : null,
      );

      // Send email
      final emailResult = await EmailService.sendEmail(
        to: tenantEmail,
        subject: 'Welcome to ${facility.name} - Your Access Information',
        html: htmlContent,
        text: 'Welcome to ${facility.name}! Your portal access code: ${portalAccessCode ?? "N/A"}. Gate access code: ${gateAccessCode ?? "N/A"}',
        facilityId: facilityId,
      );

      if (emailResult.success) {
        if (kDebugMode) {
          print('✅ Welcome email sent successfully to: $tenantEmail');
        }
      } else {
        if (kDebugMode) {
          print('❌ Failed to send welcome email: ${emailResult.error}');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error sending welcome email: $e');
      }
      // Don't throw - email failure shouldn't block tenant creation
    }
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
    if (date == null) {
      return 'Not set';
    }
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
              onChanged: (value) {
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
              onChanged: (value) {
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
                    onPressed: _pickIssuedDate,
                    icon: const Icon(Icons.calendar_month),
                    label: Text('Issued: ${_formatDate(_idIssuedDate)}'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickExpirationDate,
                    icon: const Icon(Icons.event),
                    label: Text('Expires: ${_formatDate(_idExpirationDate)}'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContactCard(int index, _ContactFieldControllers controllers) {
    final title = index == 0 ? 'Primary Contact' : 'Contact ${index + 1}';
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
              'Add emergency or alternate contacts for this tenant.',
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
              onChanged: (value) => controllers.stateController.text = value ?? '',
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
              'Track vehicles associated with this tenant for gate access and facility security.',
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
                            if (value) {
                              _ensurePortalAccessCode();
                            }
                          });
                        },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _portalEnabled
                  ? 'Tenant will have read-only access to their unit details, balances, and payment history.'
                  : 'Enable to generate a secure access code for the self-service tenant portal.',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
            if (_portalEnabled) ...[
              const SizedBox(height: 16),
              TextFormField(
                controller: _portalAccessCodeController,
                readOnly: true,
                decoration: InputDecoration(
                  labelText: 'Portal Access Code',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.vpn_key_outlined),
                  suffixIcon: Tooltip(
                    message: 'Copy to clipboard',
                    child: IconButton(
                      icon: const Icon(Icons.copy),
                      onPressed: _isLoading ? null : _copyPortalAccessCode,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _isLoading ? null : _regeneratePortalAccessCode,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Regenerate Code'),
                  ),
                  const SizedBox(width: 12),
                  TextButton.icon(
                    onPressed: _isLoading
                        ? null
                        : () {
                            _ensurePortalAccessCode();
                            _copyPortalAccessCode();
                          },
                    icon: const Icon(Icons.send_outlined),
                    label: const Text('Copy & Share'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _portalWelcomeController,
                decoration: const InputDecoration(
                  labelText: 'Welcome Message (optional)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.message_outlined),
                  hintText: 'Provide a short greeting or instructions for the portal.',
                ),
                maxLines: 2,
              ),
            ],
          ],
        ),
      ),
    );
  }
  @override
  void initState() {
    super.initState();
    _selectedFacilityId = widget.selectedFacilityId;
    _selectedIdCountry = 'United States';
    _idCountryController.text = _selectedIdCountry!;
    _contactControllers = [
      _ContactFieldControllers(isPrimary: true),
    ];
    _vehicleControllers = [];
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

  Future<void> _createTenant() async {
    if (!_formKey.currentState!.validate()) return;
    
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final idType = (_selectedIdType.isEmpty || _selectedIdType == 'none') ? null : _selectedIdType;
    final idNumberText = _idNumberController.text.trim();
    final idStateText = _idStateController.text.trim();
    final idCountryText = _idCountryController.text.trim();
    final contacts = _collectContacts();
    final vehicles = _collectVehicles();
    if (_portalEnabled) {
      _ensurePortalAccessCode();
    }
    final rawPortalAccessCode = _portalEnabled ? _portalAccessCodeController.text.trim() : null;
    final portalAccessCode = (rawPortalAccessCode != null && rawPortalAccessCode.isNotEmpty)
        ? rawPortalAccessCode
        : null;
    final rawWelcome = _portalEnabled ? _portalWelcomeController.text.trim() : null;
    final portalWelcomeMessage = (rawWelcome != null && rawWelcome.isNotEmpty) ? rawWelcome : null;

    // Check for global DNR matches before creating tenant
    if (!_dnrOverride) {
      try {
        final dnrMatches = await DNRService.findDNRMatches(
          facilityId: _selectedFacilityId,
          name: _nameController.text.trim(),
          email: _emailController.text.trim(),
          phone: _phoneController.text.trim(),
        );

        if (dnrMatches.isNotEmpty) {
          setState(() {
            _dnrMatches = dnrMatches;
            _isLoading = false;
          });

          // Show blocking dialog
          final shouldProceed = await _showDNRBlockingDialog(context, dnrMatches);
          if (!shouldProceed) {
            return; // User cancelled
          }
          // User chose to override - set flag and continue
          _dnrOverride = true;
          setState(() {
            _isLoading = true;
          });
        }
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ Error checking DNR: $e');
        }
        // Continue with tenant creation if DNR check fails (non-blocking)
      }
    }

    try {
      // Call service directly (no timeout - let it complete naturally)
      final result = await TenantService.createTenant(
        facilityId: _selectedFacilityId,
        name: _nameController.text.trim(),
        email: _emailController.text.trim(),
        phone: _phoneController.text.trim(),
        unitNumber: _unitController.text.trim(),
        monthlyRate: double.parse(_rateController.text.trim()),
        notes: _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
        governmentIdType: idType,
        governmentIdNumber: idNumberText.isNotEmpty ? idNumberText : null,
        governmentIdState: idStateText.isNotEmpty ? idStateText : null,
        governmentIdCountry: idCountryText.isNotEmpty ? idCountryText : null,
        governmentIdIssuedAt: _idIssuedDate,
        governmentIdExpiresAt: _idExpirationDate,
        emergencyContacts: contacts.isEmpty ? null : contacts,
        vehicles: vehicles.isEmpty ? null : vehicles,
        portalEnabled: _portalEnabled,
        portalAccessCode: portalAccessCode,
        portalWelcomeMessage: portalWelcomeMessage,
        leadSource: _selectedLeadSource,
      );
      
      if (kDebugMode) {
        print('✅ Tenant creation completed: $result');
      }

      // Send welcome email with access codes if portal access is enabled or gate access exists
      // Check if we should send email (portal enabled with code, or gate access exists)
      final hasPortalAccess = _portalEnabled && portalAccessCode != null && portalAccessCode.isNotEmpty;
      if (hasPortalAccess) {
        try {
          await _sendWelcomeEmailWithAccessCodes(
            tenantId: result,
            tenantName: _nameController.text.trim(),
            tenantEmail: _emailController.text.trim(),
            facilityId: _selectedFacilityId,
            unitNumber: _unitController.text.trim(),
            portalAccessCode: portalAccessCode,
            welcomeMessage: portalWelcomeMessage,
          );
        } catch (e) {
          if (kDebugMode) {
            print('⚠️ Error sending welcome email: $e');
          }
          // Don't fail tenant creation if email fails
        }
      }

      // Log DNR override if it was used
      if (_dnrOverride && _dnrMatches != null && _dnrMatches!.isNotEmpty) {
        try {
          await AuditService.logDNRAction(
            facilityId: _selectedFacilityId,
            action: 'dnr.override',
            targetId: result,
            details: {
              'tenantName': _nameController.text.trim(),
              'tenantEmail': _emailController.text.trim(),
              'matchedDnrIds': _dnrMatches!.map((m) => m.id).toList(),
              'matchedDnrNames': _dnrMatches!.map((m) => m.name).toList(),
            },
          );
        } catch (e) {
          if (kDebugMode) {
            print('⚠️ Error logging DNR override: $e');
          }
        }
      }

      if (mounted) {
        // Stop loading immediately
        setState(() {
          _isLoading = false;
        });
        
        // Show success popup
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.check_circle, color: AppTheme.success, size: 28),
                  SizedBox(width: 8),
                  Text('Success!'),
                ],
              ),
              content: Text('Your tenant "${_nameController.text}" has been created successfully!'),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop(); // Close dialog
                    // Invalidate providers to refresh tenant lists
                    ref.invalidate(allTenantsProvider);
                    // Navigate directly back to home screen
                    if (mounted) {
                        context.go(AppRoute.dashboard);
                    }
                  },
                  child: const Text('Continue'),
                ),
              ],
            );
          },
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
        });
        
        // Show error message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to create tenant: ${ErrorMessageHelper.getUserFriendlyMessage(e)}'),
            backgroundColor: AppTheme.error,
            duration: const Duration(seconds: 5),
          ),
        );
        
        // Navigate back to home screen after error
        if (kDebugMode) {
          print('🔄 Error occurred, navigating back to home screen...');
        }
        
        // Pop the tenant creation screen
        Navigator.of(context).pop();
        
        // Pop the client list screen to return to home
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted) {
            Navigator.of(context).pop();
          }
        });
      }
    }
  }

  /// Show DNR blocking dialog and return whether user wants to proceed
  Future<bool> _showDNRBlockingDialog(BuildContext context, List<DNRModel> matches) async {
    return await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.warning, color: AppTheme.error),
              const SizedBox(width: 8),
              const Text('DNR Alert - Global Match Found'),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This person matches ${matches.length} active DNR entr${matches.length == 1 ? 'y' : 'ies'} from ${matches.map((m) => m.facilityName ?? 'Unknown Facility').toSet().length} different facilit${matches.map((m) => m.facilityName ?? 'Unknown Facility').toSet().length == 1 ? 'y' : 'ies'}:',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                ...matches.map((match) => Card(
                  color: AppTheme.error.withOpacity(0.1),
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Name: ${match.name}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        if (match.email.isNotEmpty)
                          Text('Email: ${match.email}'),
                        if (match.phone.isNotEmpty)
                          Text('Phone: ${match.phone}'),
                        Text('Reason: ${match.reason}'),
                        if (match.facilityName != null)
                          Text(
                            'From Facility: ${match.facilityName}',
                            style: TextStyle(fontSize: 12, color: AppTheme.textTertiary, fontWeight: FontWeight.w500),
                          ),
                        if (match.addedByName != null && match.addedByEmail != null)
                          Text(
                            'Added by: ${match.addedByName} (${match.addedByEmail})',
                            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                          ),
                        if (match.expiresAt != null)
                          Text(
                            'Expires: ${match.expiresAt!.toLocal().toString().split(' ')[0]}',
                            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                          ),
                      ],
                    ),
                  ),
                )),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.warning.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.warning),
                  ),
                  child: const Text(
                    '⚠️ Proceeding will create this tenant despite DNR matches. This action will be logged for audit purposes.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(false); // Cancel
              },
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop(true); // Proceed with override
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.error,
                foregroundColor: AppTheme.textOnDark,
              ),
              child: const Text('Override & Continue'),
            ),
          ],
        );
      },
    ) ?? false; // Default to false if dialog is dismissed
  }

  @override
  Widget build(BuildContext context) {
    final tenantOperationState = ref.watch(tenantOperationsProvider);
    
    return ModernPageWrapper(
      currentRoute: '/tenants',
      title: 'Add New Tenant',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      child: Form(
        key: _formKey,
        child: KeyboardScrollable(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Tenant Information',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.success,
                ),
              ),
              const SizedBox(height: 24),
              
              // Facility Selection
              DropdownButtonFormField<String>(
                value: _selectedFacilityId.isEmpty ? null : _selectedFacilityId,
                decoration: const InputDecoration(
                  labelText: 'Facility *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.business),
                ),
                items: widget.facilities.map((facility) {
                  return DropdownMenuItem<String>(
                    value: facility.id,
                    child: Text(facility.name),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedFacilityId = value ?? '';
                    _selectedUnitId = null; // Reset unit selection when facility changes
                    _unitController.clear();
                    _rateController.clear();
                  });
                },
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please select a facility';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              
              // Tenant Name
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Full Name *',
                  hintText: 'e.g., John Doe',
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
                  hintText: 'john.doe@example.com',
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
                  hintText: '(555) 123-4567',
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
              
              // Unit Number
              TextFormField(
                controller: _unitController,
                decoration: const InputDecoration(
                  labelText: 'Unit Number *',
                  hintText: 'e.g., A101, 205, Storage-12',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.home),
                  helperText: 'Unit will be created on map if it doesn\'t exist',
                ),
                onChanged: (value) {
                  // Clear selected unit if manually editing
                  if (_selectedUnitId != null) {
                    setState(() {
                      _selectedUnitId = null;
                    });
                  }
                },
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a unit number';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 8),
              // Unit Selection Dropdown from Map
              if (_selectedFacilityId.isNotEmpty) ...[
                Consumer(
                  builder: (context, ref, child) {
                    final unitsAsync = ref.watch(facilityUnitsProvider(_selectedFacilityId));
                    return unitsAsync.when(
                      data: (units) {
                        if (units.isEmpty) {
                          return const SizedBox.shrink();
                        }
                        return DropdownButtonFormField<String>(
                          value: _selectedUnitId,
                          decoration: const InputDecoration(
                            labelText: 'Select from Existing Units (Optional)',
                            hintText: 'Choose a unit from the map to auto-fill details',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.map),
                            helperText: 'Selecting a unit will auto-fill the unit number and rate',
                          ),
                          items: [
                            const DropdownMenuItem<String>(
                              value: null,
                              child: Text('Enter unit number manually (will create if needed)'),
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
                                _unitController.text = unit.unitNumber;
                                _rateController.text = unit.monthlyRate.toStringAsFixed(2);
                              }
                            });
                          },
                        );
                      },
                      loading: () => const SizedBox.shrink(),
                      error: (_, __) => const SizedBox.shrink(),
                    );
                  },
                ),
              ],
              const SizedBox(height: 16),
              
              // Monthly Rate
              TextFormField(
                controller: _rateController,
                decoration: const InputDecoration(
                  labelText: 'Monthly Rate *',
                  hintText: '150.00',
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
              const SizedBox(height: 16),
              // Lead Source
              DropdownButtonFormField<String>(
                value: _selectedLeadSource,
                decoration: const InputDecoration(
                  labelText: 'Lead Source (Optional)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.trending_up),
                  helperText: 'Where did this tenant come from?',
                ),
                items: [
                  const DropdownMenuItem<String>(
                    value: null,
                    child: Text('Not Specified'),
                  ),
                  ...LeadSource.values.map((source) {
                    return DropdownMenuItem<String>(
                      value: source.name,
                      child: Text(source.displayName),
                    );
                  }),
                ],
                onChanged: (value) {
                  setState(() {
                    _selectedLeadSource = value;
                  });
                },
              ),
              const SizedBox(height: 16),
              
          _buildIdentificationSection(),
          _buildContactsSection(),
          _buildVehiclesSection(),
          _buildPortalAccessSection(),

          const SizedBox(height: 16),

              // Notes
              TextFormField(
                controller: _notesController,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  hintText: 'Additional information about the tenant...',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.note),
                ),
                maxLines: 3,
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
              
              // Create Button
              ElevatedButton(
                onPressed: _isLoading ? null : _createTenant,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.success,
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
                              Text('Creating Tenant...\nThis may take a moment'),
                            ],
                          )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.person_add),
                          SizedBox(width: 8),
                          Text('Create Tenant'),
                        ],
                      ),
              ),
              
              const SizedBox(height: 16),
              
              // Action Buttons Row
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
                      child: const Text('Done'),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : () {
                        // Clear form for another tenant
                        _nameController.clear();
                        _emailController.clear();
                        _phoneController.clear();
                        _unitController.clear();
                        _rateController.clear();
                        _notesController.clear();
                        _idNumberController.clear();
                        _idStateController.clear();
                        _portalAccessCodeController.clear();
                        _portalWelcomeController.clear();
                        _idIssuedDate = null;
                        _idExpirationDate = null;
                        for (final contact in _contactControllers) {
                          contact.dispose();
                        }
                        _contactControllers
                          ..clear()
                          ..add(_ContactFieldControllers(isPrimary: true));
                        for (final vehicle in _vehicleControllers) {
                          vehicle.dispose();
                        }
                        _vehicleControllers.clear();
                        _selectedIdType = 'none';
                        setState(() {
                          _errorMessage = null;
                          _portalEnabled = false;
                        });
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryBlue,
                        foregroundColor: AppTheme.textOnDark,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add),
                          SizedBox(width: 8),
                          Text('Add Another'),
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
  final TextEditingController nameController = TextEditingController();
  final TextEditingController relationshipController = TextEditingController();
  final TextEditingController phoneController = TextEditingController();
  final TextEditingController emailController = TextEditingController();
  bool isPrimary;
  bool isEmergency;

  _ContactFieldControllers({
    this.isPrimary = false,
    this.isEmergency = true,
  });

  void dispose() {
    nameController.dispose();
    relationshipController.dispose();
    phoneController.dispose();
    emailController.dispose();
  }
}

class _VehicleFieldControllers {
  final TextEditingController makeController = TextEditingController();
  final TextEditingController modelController = TextEditingController();
  final TextEditingController colorController = TextEditingController();
  final TextEditingController plateController = TextEditingController();
  final TextEditingController stateController = TextEditingController();
  final TextEditingController notesController = TextEditingController();

  void dispose() {
    makeController.dispose();
    modelController.dispose();
    colorController.dispose();
    plateController.dispose();
    stateController.dispose();
    notesController.dispose();
  }
}
