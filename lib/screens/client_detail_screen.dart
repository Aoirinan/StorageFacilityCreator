import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/tenant_model.dart';
import '../models/dnr_model.dart';
import '../models/payment_model.dart';
import '../models/contract_model.dart';
import '../models/provider_params.dart';
import '../providers/contract_provider.dart' as contractProv;
import '../services/dnr_service.dart';
import '../services/audit_service.dart';
import '../services/tenant_service.dart';
import '../services/reminder_service.dart';
import '../services/gate_access_service.dart';
import '../models/reminder_model.dart';
import '../models/gate_access_model.dart';
import '../providers/payment_provider.dart';
import '../providers/tenant_provider.dart';
import '../providers/ledger_provider.dart';
import '../providers/facility_provider.dart';
import '../models/ledger_entry_model.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../models/tenant_autopay_model.dart';
import '../services/autopay_service.dart';
import '../services/modern_navigation_service.dart';
import '../router/app_route.dart';
import '../widgets/keyboard_scrollable.dart';
import '../constants/location_options.dart';
import 'ledger_screen.dart';
import '../ui/payments/tenant_billing_panel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' as material;
import 'package:intl/intl.dart';

class ClientDetailScreen extends ConsumerStatefulWidget {
  final TenantModel tenant;

  const ClientDetailScreen({
    super.key,
    required this.tenant,
  });

  @override
  ConsumerState<ClientDetailScreen> createState() => _ClientDetailScreenState();
}

class _ClientDetailScreenState extends ConsumerState<ClientDetailScreen> {
  List<DNRModel>? _dnrMatches;
  bool _isCheckingDNR = false;
  bool _dnrOverride = false;
  GateAccessModel? _gateAccess;
  bool _isLoadingGateAccess = false;
  TenantModel? _tenantOverride; // Local override after month status edit
  bool _isSavingMonthStatus = false;
  bool _isAutopayLoading = false;

  final Random _random = Random.secure();

  @override
  void initState() {
    super.initState();
    _checkDNRMatches();
    _loadGateAccess();
  }

  // ── Shared helpers ─────────────────────────────────────────────────────────

  String _generateAccessCode({int length = 8}) {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    return List.generate(length, (_) => chars[_random.nextInt(chars.length)]).join();
  }

  String _formatEditDate(DateTime? date) {
    if (date == null) return 'Not set';
    return '${date.month}/${date.day}/${date.year}';
  }

  String _formatPortalTimestamp(DateTime? value) {
    if (value == null) return 'Never accessed';
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    final year = value.year;
    final hourRaw = value.hour % 12;
    final hour = hourRaw == 0 ? 12 : hourRaw;
    final minute = value.minute.toString().padLeft(2, '0');
    final suffix = value.hour >= 12 ? 'PM' : 'AM';
    return '$month/$day/$year at $hour:$minute $suffix';
  }

  // ── Per-section edit dialogs ───────────────────────────────────────────────

  Future<void> _editBasicInfo(TenantModel tenant) async {
    final nameCtrl = TextEditingController(text: tenant.name);
    final emailCtrl = TextEditingController(text: tenant.email);
    final phoneCtrl = TextEditingController(text: tenant.phone);
    final unitCtrl = TextEditingController(text: tenant.unitNumber);
    final rateCtrl = TextEditingController(text: tenant.monthlyRate.toString());
    bool smsConsent = tenant.smsOptInDate != null && !tenant.smsOptOut;
    final formKey = GlobalKey<FormState>();

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
        title: const Text('Edit Contact Information'),
        content: SingleChildScrollView(
          child: Form(
            key: formKey,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Full Name *', border: OutlineInputBorder(), prefixIcon: Icon(Icons.person)), validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null),
              const SizedBox(height: 12),
              TextFormField(controller: emailCtrl, decoration: const InputDecoration(labelText: 'Email *', border: OutlineInputBorder(), prefixIcon: Icon(Icons.email)), keyboardType: TextInputType.emailAddress, validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Required';
                if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(v)) return 'Invalid email';
                return null;
              }),
              const SizedBox(height: 12),
              TextFormField(controller: phoneCtrl, decoration: const InputDecoration(labelText: 'Phone *', border: OutlineInputBorder(), prefixIcon: Icon(Icons.phone)), keyboardType: TextInputType.phone, validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null),
              const SizedBox(height: 12),
              TextFormField(controller: unitCtrl, decoration: const InputDecoration(labelText: 'Unit Number *', border: OutlineInputBorder(), prefixIcon: Icon(Icons.home)), validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null),
              const SizedBox(height: 12),
              TextFormField(controller: rateCtrl, decoration: const InputDecoration(labelText: 'Monthly Rate *', border: OutlineInputBorder(), prefixIcon: Icon(Icons.attach_money)), keyboardType: TextInputType.number, validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Required';
                if (double.tryParse(v) == null || double.parse(v) <= 0) return 'Invalid rate';
                return null;
              }),
              const SizedBox(height: 12),
              Consumer(builder: (ctx2, ref2, _) {
                final facilityName = ref2.watch(facilityProvider(tenant.facilityId)).value?.name ?? 'this facility';
                return Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: AppTheme.backgroundSecondary, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderLight)),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Checkbox(value: smsConsent && !tenant.smsOptOut, onChanged: tenant.smsOptOut ? null : (v) => setS(() => smsConsent = v ?? false)),
                    Expanded(child: Padding(padding: const EdgeInsets.only(top: 10), child: tenant.smsOptOut
                        ? Text('Tenant opted out of SMS.', style: TextStyle(fontSize: 12, color: AppTheme.error))
                        : Text('SMS consent for $facilityName', style: const TextStyle(fontSize: 12)))),
                  ]),
                );
              }),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () { if (formKey.currentState!.validate()) Navigator.pop(ctx, true); }, child: const Text('Save')),
        ],
      )),
    );

    if (saved != true || !mounted) { nameCtrl.dispose(); emailCtrl.dispose(); phoneCtrl.dispose(); unitCtrl.dispose(); rateCtrl.dispose(); return; }

    try {
      await ref.read(tenantOperationsProvider.notifier).updateTenant(
        facilityId: tenant.facilityId, tenantId: tenant.id,
        name: nameCtrl.text.trim(), email: emailCtrl.text.trim(), phone: phoneCtrl.text.trim(),
        unitNumber: unitCtrl.text.trim(), monthlyRate: double.parse(rateCtrl.text.trim()),
        smsOptInDate: smsConsent && !tenant.smsOptOut ? DateTime.now() : null,
      );
      if (mounted) {
        ref.invalidate(facilityTenantsProvider(tenant.facilityId));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Contact info updated'), backgroundColor: AppTheme.success, duration: Duration(seconds: 2)));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()), backgroundColor: AppTheme.error));
    }
    nameCtrl.dispose(); emailCtrl.dispose(); phoneCtrl.dispose(); unitCtrl.dispose(); rateCtrl.dispose();
  }

  Future<void> _editIdentification(TenantModel tenant) async {
    final idNumCtrl = TextEditingController(text: tenant.governmentIdNumber ?? '');
    String idType = tenant.governmentIdType?.trim().isEmpty == true || tenant.governmentIdType == null ? 'none' : tenant.governmentIdType!;
    String? idState = tenant.governmentIdState;
    String? idCountry = tenant.governmentIdCountry?.isNotEmpty == true ? tenant.governmentIdCountry : 'United States';
    DateTime? issuedDate = tenant.governmentIdIssuedAt;
    DateTime? expiryDate = tenant.governmentIdExpiresAt;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
        title: const Text('Edit Identification'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<String>(
            value: idType,
            decoration: const InputDecoration(labelText: 'ID Type', border: OutlineInputBorder(), prefixIcon: Icon(Icons.badge_outlined)),
            items: const [
              DropdownMenuItem(value: 'none', child: Text('Not Captured')),
              DropdownMenuItem(value: 'drivers_license', child: Text("Driver's License")),
              DropdownMenuItem(value: 'state_id', child: Text('State ID')),
              DropdownMenuItem(value: 'passport', child: Text('Passport')),
              DropdownMenuItem(value: 'military_id', child: Text('Military ID')),
              DropdownMenuItem(value: 'other', child: Text('Other')),
            ],
            onChanged: (v) => setS(() => idType = v ?? 'none'),
          ),
          const SizedBox(height: 12),
          TextFormField(controller: idNumCtrl, decoration: const InputDecoration(labelText: 'ID Number', border: OutlineInputBorder(), prefixIcon: Icon(Icons.confirmation_number_outlined))),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: idState?.isNotEmpty == true ? idState : null,
            decoration: const InputDecoration(labelText: 'Issuing State', border: OutlineInputBorder(), prefixIcon: Icon(Icons.flag_outlined)),
            items: [const DropdownMenuItem<String>(value: '', child: Text('Not Selected')), ...kUsStateMap.entries.map((e) => DropdownMenuItem<String>(value: e.key, child: Text('${e.key} — ${e.value}')))],
            onChanged: (v) => setS(() => idState = (v == null || v.isEmpty) ? null : v),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: idCountry?.isNotEmpty == true ? idCountry : null,
            decoration: const InputDecoration(labelText: 'Issuing Country', border: OutlineInputBorder(), prefixIcon: Icon(Icons.public_outlined)),
            items: [const DropdownMenuItem<String>(value: '', child: Text('Not Selected')), ...kDefaultCountryPriority.map((c) => DropdownMenuItem<String>(value: c, child: Text(c))), ...kCountryList.where((c) => !kDefaultCountryPriority.contains(c)).map((c) => DropdownMenuItem<String>(value: c, child: Text(c)))],
            onChanged: (v) => setS(() => idCountry = (v == null || v.isEmpty) ? null : v),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: OutlinedButton.icon(
              onPressed: () async {
                final d = await showDatePicker(context: ctx, initialDate: issuedDate ?? DateTime.now().subtract(const Duration(days: 30)), firstDate: DateTime.now().subtract(const Duration(days: 3650)), lastDate: DateTime.now().add(const Duration(days: 365)));
                if (d != null) setS(() => issuedDate = d);
              },
              icon: const Icon(Icons.calendar_month, size: 16),
              label: Text('Issued: ${_formatEditDate(issuedDate)}', style: const TextStyle(fontSize: 12)),
            )),
            if (issuedDate != null) IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: () => setS(() => issuedDate = null)),
            const SizedBox(width: 4),
            Expanded(child: OutlinedButton.icon(
              onPressed: () async {
                final d = await showDatePicker(context: ctx, initialDate: expiryDate ?? DateTime.now().add(const Duration(days: 365)), firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 3650)));
                if (d != null) setS(() => expiryDate = d);
              },
              icon: const Icon(Icons.event, size: 16),
              label: Text('Expires: ${_formatEditDate(expiryDate)}', style: const TextStyle(fontSize: 12)),
            )),
            if (expiryDate != null) IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: () => setS(() => expiryDate = null)),
          ]),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      )),
    );

    if (saved != true || !mounted) { idNumCtrl.dispose(); return; }
    try {
      await ref.read(tenantOperationsProvider.notifier).updateTenant(
        facilityId: tenant.facilityId, tenantId: tenant.id,
        governmentIdType: (idType == 'none') ? '' : idType,
        governmentIdNumber: idNumCtrl.text.trim(),
        governmentIdState: idState ?? '',
        governmentIdCountry: idCountry ?? '',
        governmentIdIssuedAt: issuedDate,
        governmentIdExpiresAt: expiryDate,
        clearGovernmentIdIssuedAt: issuedDate == null && tenant.governmentIdIssuedAt != null,
        clearGovernmentIdExpiresAt: expiryDate == null && tenant.governmentIdExpiresAt != null,
      );
      if (mounted) {
        ref.invalidate(facilityTenantsProvider(tenant.facilityId));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Identification updated'), backgroundColor: AppTheme.success, duration: Duration(seconds: 2)));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()), backgroundColor: AppTheme.error));
    }
    idNumCtrl.dispose();
  }

  Future<void> _editContacts(TenantModel tenant) async {
    final controllers = tenant.emergencyContacts.isNotEmpty
        ? tenant.emergencyContacts.map((c) => _ContactFieldControllers(isPrimary: c.isPrimary, isEmergency: c.isEmergency, name: c.name, relationship: c.relationship, phone: c.phone, email: c.email)).toList()
        : [_ContactFieldControllers(isPrimary: true)];

    List<TenantContact> _collect(List<_ContactFieldControllers> ctrls) {
      final contacts = <TenantContact>[];
      for (final e in ctrls) {
        final name = e.nameController.text.trim();
        final rel = e.relationshipController.text.trim();
        final ph = e.phoneController.text.trim();
        final em = e.emailController.text.trim();
        if ([name, rel, ph, em].every((v) => v.isEmpty)) continue;
        contacts.add(TenantContact(name: name.isNotEmpty ? name : (rel.isNotEmpty ? rel : ph.isNotEmpty ? ph : 'Contact'), relationship: rel.isNotEmpty ? rel : null, phone: ph.isNotEmpty ? ph : null, email: em.isNotEmpty ? em : null, isPrimary: e.isPrimary, isEmergency: e.isEmergency));
      }
      if (contacts.isNotEmpty && !contacts.any((c) => c.isPrimary)) {
        final f = contacts.first;
        contacts[0] = TenantContact(name: f.name, relationship: f.relationship, phone: f.phone, email: f.email, isPrimary: true, isEmergency: f.isEmergency);
      }
      return contacts;
    }

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
        title: Row(children: [
          const Expanded(child: Text('Edit Contacts')),
          TextButton.icon(onPressed: () => setS(() => controllers.add(_ContactFieldControllers())), icon: const Icon(Icons.add, size: 16), label: const Text('Add')),
        ]),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: List.generate(controllers.length, (i) {
            final ctrl = controllers[i];
            return Card(margin: const EdgeInsets.only(bottom: 12), child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(ctrl.isPrimary ? 'Primary Contact' : 'Contact ${i + 1}', style: const TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                if (controllers.length > 1) IconButton(icon: Icon(Icons.delete_outline, color: AppTheme.error, size: 18), onPressed: () => setS(() { final r = controllers.removeAt(i); r.dispose(); })),
              ]),
              const SizedBox(height: 8),
              TextFormField(controller: ctrl.nameController, decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder(), isDense: true)),
              const SizedBox(height: 8),
              TextFormField(controller: ctrl.relationshipController, decoration: const InputDecoration(labelText: 'Relationship', border: OutlineInputBorder(), isDense: true)),
              const SizedBox(height: 8),
              TextFormField(controller: ctrl.phoneController, decoration: const InputDecoration(labelText: 'Phone', border: OutlineInputBorder(), isDense: true), keyboardType: TextInputType.phone),
              const SizedBox(height: 8),
              TextFormField(controller: ctrl.emailController, decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder(), isDense: true), keyboardType: TextInputType.emailAddress),
              Row(children: [
                Expanded(child: SwitchListTile(title: const Text('Primary', style: TextStyle(fontSize: 13)), value: ctrl.isPrimary, onChanged: (v) => setS(() { for (var j = 0; j < controllers.length; j++) controllers[j].isPrimary = v && j == i; if (!controllers.any((c) => c.isPrimary)) controllers.first.isPrimary = true; }), contentPadding: EdgeInsets.zero, dense: true)),
                Expanded(child: SwitchListTile(title: const Text('Emergency', style: TextStyle(fontSize: 13)), value: ctrl.isEmergency, onChanged: (v) => setS(() => ctrl.isEmergency = v), contentPadding: EdgeInsets.zero, dense: true)),
              ]),
            ])));
          }))),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      )),
    );

    if (saved != true || !mounted) { for (final c in controllers) c.dispose(); return; }
    try {
      await ref.read(tenantOperationsProvider.notifier).updateTenant(facilityId: tenant.facilityId, tenantId: tenant.id, emergencyContacts: _collect(controllers));
      if (mounted) {
        ref.invalidate(facilityTenantsProvider(tenant.facilityId));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Contacts updated'), backgroundColor: AppTheme.success, duration: Duration(seconds: 2)));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()), backgroundColor: AppTheme.error));
    }
    for (final c in controllers) c.dispose();
  }

  Future<void> _editVehicles(TenantModel tenant) async {
    final controllers = tenant.vehicles.map((v) => _VehicleFieldControllers(make: v.make, model: v.model, color: v.color, plate: v.licensePlate, state: v.state, notes: v.notes)).toList();

    List<TenantVehicle> _collect(List<_VehicleFieldControllers> ctrls) {
      final vehicles = <TenantVehicle>[];
      for (final e in ctrls) {
        final make = e.makeController.text.trim();
        final model = e.modelController.text.trim();
        final plate = e.plateController.text.trim();
        final notes = e.notesController.text.trim();
        if (make.isEmpty && model.isEmpty && plate.isEmpty && notes.isEmpty) continue;
        vehicles.add(TenantVehicle(make: make.isNotEmpty ? make : 'Vehicle', model: model, color: e.colorController.text.trim().isNotEmpty ? e.colorController.text.trim() : null, licensePlate: plate.isNotEmpty ? plate : null, state: e.stateController.text.trim().isNotEmpty ? e.stateController.text.trim() : null, notes: notes.isNotEmpty ? notes : null));
      }
      return vehicles;
    }

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
        title: Row(children: [
          const Expanded(child: Text('Edit Vehicles')),
          TextButton.icon(onPressed: () => setS(() => controllers.add(_VehicleFieldControllers())), icon: const Icon(Icons.add, size: 16), label: const Text('Add')),
        ]),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: controllers.isEmpty
            ? [const Text('No vehicles. Tap Add to add one.', style: TextStyle(color: AppTheme.textSecondary))]
            : List.generate(controllers.length, (i) {
              final ctrl = controllers[i];
              return Card(margin: const EdgeInsets.only(bottom: 12), child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text('Vehicle ${i + 1}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  IconButton(icon: Icon(Icons.delete_outline, color: AppTheme.error, size: 18), onPressed: () => setS(() { final r = controllers.removeAt(i); r.dispose(); })),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: TextFormField(controller: ctrl.makeController, decoration: const InputDecoration(labelText: 'Make', border: OutlineInputBorder(), isDense: true))),
                  const SizedBox(width: 8),
                  Expanded(child: TextFormField(controller: ctrl.modelController, decoration: const InputDecoration(labelText: 'Model', border: OutlineInputBorder(), isDense: true))),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: TextFormField(controller: ctrl.colorController, decoration: const InputDecoration(labelText: 'Color', border: OutlineInputBorder(), isDense: true))),
                  const SizedBox(width: 8),
                  Expanded(child: TextFormField(controller: ctrl.plateController, decoration: const InputDecoration(labelText: 'License Plate', border: OutlineInputBorder(), isDense: true))),
                ]),
                const SizedBox(height: 8),
                StatefulBuilder(builder: (ctx2, setS2) => DropdownButtonFormField<String>(
                  value: ctrl.stateController.text.isNotEmpty ? ctrl.stateController.text : null,
                  decoration: const InputDecoration(labelText: 'Plate State', border: OutlineInputBorder(), isDense: true),
                  items: [const DropdownMenuItem<String>(value: '', child: Text('Not Selected')), ...kUsStateMap.entries.map((e) => DropdownMenuItem<String>(value: e.key, child: Text(e.key)))],
                  onChanged: (v) { ctrl.stateController.text = v ?? ''; setS2(() {}); },
                )),
                const SizedBox(height: 8),
                TextFormField(controller: ctrl.notesController, decoration: const InputDecoration(labelText: 'Notes', border: OutlineInputBorder(), isDense: true), maxLines: 2),
              ])));
            })
          )),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      )),
    );

    if (saved != true || !mounted) { for (final c in controllers) c.dispose(); return; }
    try {
      await ref.read(tenantOperationsProvider.notifier).updateTenant(facilityId: tenant.facilityId, tenantId: tenant.id, vehicles: _collect(controllers));
      if (mounted) {
        ref.invalidate(facilityTenantsProvider(tenant.facilityId));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Vehicles updated'), backgroundColor: AppTheme.success, duration: Duration(seconds: 2)));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()), backgroundColor: AppTheme.error));
    }
    for (final c in controllers) c.dispose();
  }

  Future<void> _editPortal(TenantModel tenant) async {
    bool portalEnabled = tenant.portalEnabled;
    final codeCtrl = TextEditingController(text: tenant.portalAccessCode ?? '');
    final welcomeCtrl = TextEditingController(text: tenant.portalWelcomeMessage ?? '');
    if (portalEnabled && codeCtrl.text.trim().isEmpty) codeCtrl.text = _generateAccessCode();

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
        title: const Text('Edit Tenant Portal'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          SwitchListTile(
            title: const Text('Portal Access Enabled'),
            subtitle: Text(portalEnabled ? 'Tenant can log in with access code' : 'Portal is disabled'),
            value: portalEnabled,
            onChanged: (v) => setS(() { portalEnabled = v; if (v && codeCtrl.text.trim().isEmpty) codeCtrl.text = _generateAccessCode(); }),
            contentPadding: EdgeInsets.zero,
          ),
          if (portalEnabled) ...[
            const SizedBox(height: 12),
            TextFormField(
              controller: codeCtrl,
              decoration: InputDecoration(
                labelText: 'Access Code',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.vpn_key_outlined),
                suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(icon: const Icon(Icons.copy, size: 18), tooltip: 'Copy', onPressed: () async { await Clipboard.setData(ClipboardData(text: codeCtrl.text.trim())); if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Copied'))); }),
                  IconButton(icon: const Icon(Icons.refresh, size: 18), tooltip: 'Regenerate', onPressed: () => setS(() => codeCtrl.text = _generateAccessCode())),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(controller: welcomeCtrl, decoration: const InputDecoration(labelText: 'Welcome Message (optional)', border: OutlineInputBorder(), hintText: 'Shown on tenant portal dashboard'), maxLines: 2),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 4, children: [
              Chip(avatar: const Icon(Icons.access_time, size: 14), label: Text(_formatPortalTimestamp(tenant.portalLastAccessAt), style: const TextStyle(fontSize: 12))),
              Chip(avatar: const Icon(Icons.analytics_outlined, size: 14), label: Text('Visits: ${tenant.portalVisitCount}', style: const TextStyle(fontSize: 12))),
            ]),
          ],
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      )),
    );

    if (saved != true || !mounted) { codeCtrl.dispose(); welcomeCtrl.dispose(); return; }
    final trimmedCode = codeCtrl.text.trim();
    final portalAccessCode = portalEnabled && trimmedCode.isNotEmpty ? trimmedCode : null;
    final shouldClearCode = !portalEnabled && (tenant.portalAccessCode?.isNotEmpty ?? false);
    final resetStats = portalAccessCode != null && portalAccessCode != tenant.portalAccessCode;
    try {
      await ref.read(tenantOperationsProvider.notifier).updateTenant(
        facilityId: tenant.facilityId, tenantId: tenant.id,
        portalEnabled: portalEnabled,
        portalAccessCode: portalAccessCode,
        clearPortalAccessCode: shouldClearCode,
        portalWelcomeMessage: portalEnabled ? (welcomeCtrl.text.trim().isNotEmpty ? welcomeCtrl.text.trim() : null) : '',
        portalLastAccessAt: tenant.portalLastAccessAt,
        resetPortalStats: resetStats,
      );
      if (mounted) {
        ref.invalidate(facilityTenantsProvider(tenant.facilityId));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Portal settings updated'), backgroundColor: AppTheme.success, duration: Duration(seconds: 2)));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()), backgroundColor: AppTheme.error));
    }
    codeCtrl.dispose(); welcomeCtrl.dispose();
  }

  Future<void> _editAccountStatus(TenantModel tenant) async {
    bool isActive = tenant.isActive;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
        title: const Text('Edit Account Status'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          SwitchListTile(
            title: const Text('Active Tenant'),
            subtitle: const Text('Tenant is currently renting'),
            value: isActive,
            onChanged: (v) => setS(() => isActive = v),
            secondary: Icon(isActive ? Icons.check_circle : Icons.cancel, color: isActive ? AppTheme.success : AppTheme.error),
            contentPadding: EdgeInsets.zero,
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      )),
    );

    if (saved != true || !mounted) return;
    try {
      await ref.read(tenantOperationsProvider.notifier).updateTenant(facilityId: tenant.facilityId, tenantId: tenant.id, isActive: isActive);
      if (mounted) {
        ref.invalidate(facilityTenantsProvider(tenant.facilityId));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Status updated'), backgroundColor: AppTheme.success, duration: Duration(seconds: 2)));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()), backgroundColor: AppTheme.error));
    }
  }

  Future<void> _editNotes(TenantModel tenant) async {
    final ctrl = TextEditingController(text: tenant.notes ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Notes'),
        content: TextFormField(controller: ctrl, decoration: const InputDecoration(labelText: 'Notes', border: OutlineInputBorder(), hintText: 'Any additional information about this tenant...'), maxLines: 5, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );

    if (saved != true || !mounted) { ctrl.dispose(); return; }
    try {
      await ref.read(tenantOperationsProvider.notifier).updateTenant(facilityId: tenant.facilityId, tenantId: tenant.id, notes: ctrl.text.trim().isEmpty ? null : ctrl.text.trim());
      if (mounted) {
        ref.invalidate(facilityTenantsProvider(tenant.facilityId));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Notes updated'), backgroundColor: AppTheme.success, duration: Duration(seconds: 2)));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()), backgroundColor: AppTheme.error));
    }
    ctrl.dispose();
  }

  // ── End per-section edit dialogs ───────────────────────────────────────────

  Future<void> _loadGateAccess() async {
    setState(() {
      _isLoadingGateAccess = true;
    });

    try {
      final gateAccess = await GateAccessService.getGateAccessForTenant(
        facilityId: widget.tenant.facilityId,
        tenantId: widget.tenant.id,
      );

      if (mounted) {
        setState(() {
          _gateAccess = gateAccess;
          _isLoadingGateAccess = false;
        });
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error loading gate access: $e');
      }
      if (mounted) {
        setState(() {
          _isLoadingGateAccess = false;
        });
      }
    }
  }

  Future<void> _toggleGateAccess() async {
    if (_gateAccess == null) return;

    final newStatus = !_gateAccess!.isActive;

    try {
      await GateAccessService.updateGateAccess(
        facilityId: widget.tenant.facilityId,
        accessId: _gateAccess!.id,
        isActive: newStatus,
      );

      // Reload gate access
      await _loadGateAccess();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              newStatus ? 'Gate access enabled' : 'Gate access disabled',
            ),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error updating gate access: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Widget _buildAutopayCard(BuildContext context, TenantModel tenant) {
    final autopay = tenant.autopay;
    final stripe = tenant.stripe;
    final theme = Theme.of(context);

    Widget statusChip;
    switch (autopay.status) {
      case AutopayStatus.off:
        statusChip = Chip(
          avatar: const Icon(Icons.toggle_off, color: AppTheme.textSecondary, size: 20),
          label: const Text('OFF'),
          backgroundColor: AppTheme.textSecondary.withOpacity(0.1),
        );
        break;
      case AutopayStatus.requested:
        statusChip = Chip(
          avatar: const Icon(Icons.schedule, color: AppTheme.warning, size: 20),
          label: const Text('REQUESTED'),
          backgroundColor: AppTheme.warning.withOpacity(0.1),
        );
        break;
      case AutopayStatus.on:
        statusChip = Chip(
          avatar: const Icon(Icons.check_circle, color: AppTheme.success, size: 20),
          label: const Text('ON'),
          backgroundColor: AppTheme.success.withOpacity(0.1),
        );
        break;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.autorenew, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Autopay', style: theme.textTheme.titleMedium),
                const SizedBox(width: 12),
                statusChip,
              ],
            ),
            if (stripe.hasPaymentMethod && stripe.paymentMethodSummary != null) ...[
              const SizedBox(height: 8),
              Text('Card: ${stripe.paymentMethodSummary!.displayLabel}', style: theme.textTheme.bodySmall),
            ],
            if (autopay.updatedAt != null) ...[
              const SizedBox(height: 4),
              Text(
                'Updated by ${autopay.updatedBy.value} • ${_formatDateTime(autopay.updatedAt)}',
                style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                if (!autopay.isOn)
                  ElevatedButton.icon(
                    onPressed: _isAutopayLoading ? null : () => _setAutopay(true, tenant),
                    icon: _isAutopayLoading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.check_circle_outline, size: 18),
                    label: const Text('Enable autopay'),
                  ),
                if (!autopay.isOn) const SizedBox(width: 12),
                if (autopay.isOn)
                  OutlinedButton.icon(
                    onPressed: _isAutopayLoading ? null : () => _setAutopay(false, tenant),
                    icon: const Icon(Icons.cancel_outlined, size: 18),
                    label: const Text('Disable autopay'),
                    style: OutlinedButton.styleFrom(foregroundColor: AppTheme.error),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _setAutopay(bool enabled, TenantModel tenant) async {
    setState(() => _isAutopayLoading = true);
    try {
      await AutopayService.setTenantAutopay(
        facilityId: tenant.facilityId,
        tenantId: tenant.id,
        enabled: enabled,
        source: 'FACILITY',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(enabled ? 'Autopay enabled.' : 'Autopay disabled.'), backgroundColor: AppTheme.success),
        );
        ref.invalidate(facilityTenantsProvider(tenant.facilityId));
      }
    } catch (e) {
      if (mounted) {
        final msg = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: AppTheme.error));
      }
    } finally {
      if (mounted) setState(() => _isAutopayLoading = false);
    }
  }

  Future<void> _checkDNRMatches() async {
    if (_dnrOverride) return; // Skip if already overridden
    
    setState(() {
      _isCheckingDNR = true;
    });

    try {
      final matches = await DNRService.findDNRMatches(
        facilityId: widget.tenant.facilityId,
        name: widget.tenant.name,
        email: widget.tenant.email,
        phone: widget.tenant.phone,
      );

      if (mounted) {
        setState(() {
          _dnrMatches = matches;
          _isCheckingDNR = false;
        });

        // Show blocking dialog if matches found
        if (matches.isNotEmpty) {
          _showDNRBlockingDialog(context, matches);
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error checking DNR matches: $e');
      }
      if (mounted) {
        setState(() {
          _isCheckingDNR = false;
        });
      }
    }
  }

  void _showDNRBlockingDialog(BuildContext context, List<DNRModel> matches) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.warning, color: AppTheme.error),
              const SizedBox(width: 8),
              const Text('DNR Alert'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This tenant matches ${matches.length} active DNR entr${matches.length == 1 ? 'y' : 'ies'}:',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              ...matches.map((match) => Card(
                color: AppTheme.error.withOpacity(0.1),
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
                      if (match.addedByName != null && match.addedByEmail != null)
                        Text(
                          'Added by: ${match.addedByName} (${match.addedByEmail})',
                          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                        ),
                      if (match.facilityName != null)
                        Text(
                          'Facility: ${match.facilityName}',
                          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                        ),
                      if (match.expiresAt != null)
                        Text('Expires: ${match.expiresAt!.toLocal().toString().split(' ')[0]}'),
                    ],
                  ),
                ),
              )),
              const SizedBox(height: 16),
              const Text(
                'Do you want to override and continue?',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(); // Close dialog
                Navigator.of(context).pop(); // Go back to tenant list
              },
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _dnrOverride = true;
                });
                Navigator.of(context).pop(); // Close dialog
                _logDNROverride(matches);
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
    );
  }

  Future<void> _logDNROverride(List<DNRModel> matches) async {
    try {
      // Log the override action for audit purposes
      await AuditService.logDNRAction(
        facilityId: widget.tenant.facilityId,
        action: 'dnr.override',
        targetId: widget.tenant.id,
        details: {
          'tenantName': widget.tenant.name,
          'tenantEmail': widget.tenant.email,
          'matchedDnrIds': matches.map((m) => m.id).toList(),
          'matchedDnrNames': matches.map((m) => m.name).toList(),
        },
      );

      if (kDebugMode) {
        print('✅ DNR override logged for tenant: ${widget.tenant.name}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error logging DNR override: $e');
      }
      // Don't rethrow - logging is non-critical
    }
  }

  String _formatDateTime(DateTime? date) {
    if (date == null) return 'Not specified';
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    final year = date.year;
    final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
    final minute = date.minute.toString().padLeft(2, '0');
    final period = date.hour >= 12 ? 'PM' : 'AM';
    return '$month/$day/$year $hour:$minute $period';
  }

  String _formatDate(DateTime? date) {
    if (date == null) return 'Not specified';
    return '${date.month}/${date.day}/${date.year}';
  }

  String _displayIdType(String? type) {
    switch (type) {
      case 'drivers_license':
        return 'Driver\'s License';
      case 'state_id':
        return 'State ID';
      case 'passport':
        return 'Passport';
      case 'military_id':
        return 'Military ID';
      case 'other':
        return 'Other';
      default:
        return 'Not specified';
    }
  }

  @override
  Widget build(BuildContext context) {
    final tenantsAsync = ref.watch(facilityTenantsProvider(widget.tenant.facilityId));
    final tenant = tenantsAsync.maybeWhen(
      data: (tenants) {
        try {
          return tenants.firstWhere((t) => t.id == widget.tenant.id);
        } catch (_) {
          return widget.tenant;
        }
      },
      orElse: () => widget.tenant,
    );

    return SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_dnrMatches != null && _dnrMatches!.isNotEmpty && !_dnrOverride)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppTheme.error.withOpacity(0.1),
                    border: Border.all(color: AppTheme.error),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.warning, color: AppTheme.error),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'DNR ALERT: ${_dnrMatches!.length} Active DNR Matches Found',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: AppTheme.error,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'This tenant matches active Do Not Rent entries. Review carefully before proceeding.',
                              style: TextStyle(color: AppTheme.error),
                            ),
                            if (_dnrMatches!.isNotEmpty && _dnrMatches!.first.addedByName != null && _dnrMatches!.first.addedByEmail != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  'DNR entries added by: ${_dnrMatches!.first.addedByName} (${_dnrMatches!.first.addedByEmail})',
                                  style: TextStyle(fontSize: 12, color: AppTheme.error),
                                ),
                              ),
                            if (_dnrMatches!.isNotEmpty && _dnrMatches!.first.facilityName != null)
                              Text(
                                'Facility: ${_dnrMatches!.first.facilityName}',
                                style: TextStyle(fontSize: 12, color: AppTheme.error),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              if (_dnrOverride)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppTheme.warning.withOpacity(0.1),
                    border: Border.all(color: AppTheme.warning),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle, color: AppTheme.warning),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'DNR Override Active: Proceeding with caution',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: AppTheme.warning,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (tenant.overlockIsActive)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppTheme.error.withOpacity(0.1),
                    border: Border.all(color: AppTheme.error),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.lock, color: AppTheme.error),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Unit is overlocked',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: AppTheme.error,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'This tenant\'s unit is currently overlocked. Manage from Manager Overlock.',
                              style: TextStyle(color: AppTheme.error),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 30,
                        backgroundColor: tenant.isActive ? AppTheme.success : AppTheme.textTertiary,
                        child: Text(
                          tenant.name.isNotEmpty ? tenant.name[0].toUpperCase() : '?',
                          style: const TextStyle(
                            color: AppTheme.textOnDark,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              tenant.name,
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Unit ${tenant.unitNumber}',
                              style: TextStyle(
                                fontSize: 16,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: tenant.isActive ? AppTheme.success.withOpacity(0.1) : AppTheme.backgroundLight,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                tenant.isActive ? 'Active' : 'Inactive',
                                style: TextStyle(
                                  color: tenant.isActive ? AppTheme.success : AppTheme.textTertiary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Quick actions: Ledger and key links so they're visible without scrolling
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Quick actions',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: AppTheme.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          FilledButton.icon(
                            onPressed: () {
                              context.push(
                                '/tenants/${tenant.id}/ledger?facilityId=${tenant.facilityId}',
                                extra: tenant,
                              );
                            },
                            icon: const Icon(Icons.receipt_long, size: 20),
                            label: const Text('View Ledger'),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppTheme.primaryBlue,
                              foregroundColor: AppTheme.textOnDark,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: () {
                              context.push(
                                Uri(
                                  path: AppRoute.pos,
                                  queryParameters: {
                                    'facilityId': tenant.facilityId,
                                    'tenantId': tenant.id,
                                  },
                                ).toString(),
                                extra: tenant,
                              );
                            },
                            icon: const Icon(Icons.point_of_sale_outlined, size: 20),
                            label: const Text('Store sale'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader(context, Icons.contact_mail_outlined, 'Contact Information', onEdit: () => _editBasicInfo(tenant)),
                      _buildInfoItem(context, icon: Icons.person_outlined, label: 'Name', value: _valueOrPlaceholder(tenant.name)),
                      _buildInfoItem(context, icon: Icons.email_outlined, label: 'Email', value: _valueOrPlaceholder(tenant.email)),
                      _buildInfoItem(context, icon: Icons.phone_outlined, label: 'Phone', value: _valueOrPlaceholder(tenant.phone)),
                      _buildInfoItem(context, icon: Icons.home_work_outlined, label: 'Unit', value: _valueOrPlaceholder(tenant.unitNumber, fallback: 'No unit assigned')),
                      _buildInfoItem(context, icon: Icons.attach_money, label: 'Monthly Rate', value: _formatCurrency(tenant.monthlyRate)),
                      if (tenant.smsOptOut)
                        _buildInfoItem(context, icon: Icons.sms_failed_outlined, label: 'SMS', value: 'Opted out', valueColor: AppTheme.error)
                      else if (tenant.smsOptInDate != null)
                        _buildInfoItem(context, icon: Icons.sms_outlined, label: 'SMS', value: 'Opted in'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader(context, Icons.badge_outlined, 'Identification', onEdit: () => _editIdentification(tenant)),
                      _buildInfoItem(context, icon: Icons.assignment_ind_outlined, label: 'ID Type', value: _displayIdType(tenant.governmentIdType)),
                      _buildInfoItem(context, icon: Icons.confirmation_number_outlined, label: 'ID Number', value: _valueOrPlaceholder(tenant.governmentIdNumber)),
                      _buildInfoItem(context, icon: Icons.flag_outlined, label: 'Issuing State', value: _valueOrPlaceholder(tenant.governmentIdState)),
                      _buildInfoItem(context, icon: Icons.public_outlined, label: 'Issuing Country', value: _valueOrPlaceholder(tenant.governmentIdCountry)),
                      _buildInfoItem(context, icon: Icons.calendar_month_outlined, label: 'Issued', value: _formatDate(tenant.governmentIdIssuedAt)),
                      _buildInfoItem(context, icon: Icons.event_outlined, label: 'Expires', value: _formatDate(tenant.governmentIdExpiresAt)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader(context, Icons.group_outlined, 'Emergency Contacts', onEdit: () => _editContacts(tenant)),
                      if (tenant.emergencyContacts.isEmpty)
                        _buildPlaceholder(context, 'No emergency contacts on file.')
                      else
                        ...tenant.emergencyContacts.map((contact) {
                          final details = <String>[];
                          if (contact.relationship?.isNotEmpty == true) details.add(contact.relationship!);
                          if (contact.phone?.isNotEmpty == true) details.add(contact.phone!);
                          if (contact.email?.isNotEmpty == true) details.add(contact.email!);
                          if (contact.isPrimary) details.add('Primary');
                          if (contact.isEmergency) details.add('Emergency Ready');
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(contact.isEmergency ? Icons.warning_amber_outlined : Icons.contact_page_outlined, color: contact.isEmergency ? AppTheme.error : AppTheme.textSecondary),
                            title: Text(contact.name),
                            subtitle: Text(details.isNotEmpty ? details.join(' • ') : 'No additional details'),
                          );
                        }),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader(context, Icons.directions_car_filled_outlined, 'Vehicles', onEdit: () => _editVehicles(tenant)),
                      if (tenant.vehicles.isEmpty)
                        _buildPlaceholder(context, 'No vehicles registered.')
                      else
                        ...tenant.vehicles.map((vehicle) {
                          final details = <String>[];
                          if (vehicle.licensePlate?.isNotEmpty == true) details.add('Plate: ${vehicle.licensePlate}');
                          if (vehicle.state?.isNotEmpty == true) details.add('State: ${vehicle.state}');
                          if (vehicle.color?.isNotEmpty == true) details.add(vehicle.color!);
                          if (vehicle.notes?.isNotEmpty == true) details.add(vehicle.notes!);
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.directions_car),
                            title: Text('${vehicle.make} ${vehicle.model}'.trim().isNotEmpty ? '${vehicle.make} ${vehicle.model}'.trim() : 'Vehicle'),
                            subtitle: Text(details.isNotEmpty ? details.join(' • ') : 'No additional details'),
                          );
                        }),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader(context, Icons.lock_outline, 'Tenant Portal', onEdit: () => _editPortal(tenant)),
                      _buildInfoItem(context, icon: Icons.toggle_on_outlined, label: 'Portal Access', value: tenant.portalEnabled ? 'Enabled' : 'Disabled'),
                      _buildInfoItem(context, icon: Icons.key_outlined, label: 'Access Code', value: tenant.portalEnabled ? _valueOrPlaceholder(tenant.portalAccessCode, fallback: 'Not set') : 'Not applicable'),
                      _buildInfoItem(context, icon: Icons.message_outlined, label: 'Welcome Message', value: tenant.portalEnabled ? _valueOrPlaceholder(tenant.portalWelcomeMessage) : 'Not applicable'),
                      _buildInfoItem(context, icon: Icons.history, label: 'Last Accessed', value: tenant.portalEnabled ? _formatDateTime(tenant.portalLastAccessAt) : 'Not applicable'),
                      if (tenant.portalEnabled)
                        _buildInfoItem(context, icon: Icons.bar_chart_outlined, label: 'Portal Visits', value: tenant.portalVisitCount.toString()),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader(context, Icons.info_outline, 'Account Status', onEdit: () => _editAccountStatus(tenant)),
                      _buildInfoItem(context, icon: Icons.warning_amber_outlined, label: 'DNR Flag', value: tenant.isOnDNR ? 'On Do Not Rent list' : 'Cleared'),
                      _buildInfoItem(context, icon: Icons.person_outline, label: 'Active Status', value: tenant.isActive ? 'Active' : 'Inactive'),
                      _buildInfoItem(context, icon: Icons.calendar_today_outlined, label: 'Created At', value: _formatDateTime(tenant.createdAt)),
                      _buildInfoItem(context, icon: Icons.update, label: 'Updated At', value: _formatDateTime(tenant.updatedAt)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader(context, Icons.attach_money_outlined, 'Financial Summary'),
                      _buildInfoItem(context, icon: Icons.attach_money, label: 'Monthly Rate', value: _formatCurrency(tenant.monthlyRate)),
                      _buildInfoItem(
                        context,
                        icon: Icons.calendar_today_outlined,
                        label: 'Paid Through',
                        value: tenant.paidThrough != null ? '${tenant.paidThrough!.month}/${tenant.paidThrough!.year}' : 'Not paid',
                        onEdit: () => _showEditPaidThroughDialog(tenant),
                      ),
                      _buildInfoItem(
                        context,
                        icon: Icons.warning_amber,
                        label: 'Payment Status',
                        value: tenant.isLate ? 'Late (${tenant.daysLate} days)' : 'Current',
                      ),
                      const SizedBox(height: 16),
                      _buildPaymentHistorySummary(_tenantOverride ?? tenant),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            context.push(
                              '/tenants/${tenant.id}/ledger?facilityId=${tenant.facilityId}',
                              extra: tenant,
                            );
                          },
                          icon: const Icon(Icons.receipt_long),
                          label: const Text('View Ledger'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primaryBlue,
                            foregroundColor: AppTheme.textOnDark,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Autopay status + facility controls
              const SizedBox(height: 16),
              _buildAutopayCard(context, tenant),
              // Stripe payments (Add Card, AutoPay, One-Time)
              const SizedBox(height: 16),
              TenantBillingPanel(
                facilityId: tenant.facilityId,
                tenantId: tenant.id,
                tenantName: tenant.name,
                defaultPaymentMethodId: tenant.stripe?.defaultPaymentMethodId,
              ),
              // Gate Access Section
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.lock_outline, color: AppTheme.textTertiary),
                          const SizedBox(width: 8),
                          Text(
                            'Gate Access',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          if (_isLoadingGateAccess)
                            const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (_gateAccess != null) ...[
                        _buildInfoItem(
                          context,
                          icon: Icons.key,
                          label: 'Access Code',
                          value: _gateAccess!.accessCode,
                        ),
                        _buildInfoItem(
                          context,
                          icon: _gateAccess!.isActive ? Icons.check_circle : Icons.cancel,
                          label: 'Status',
                          value: _gateAccess!.isActive ? 'Enabled' : 'Disabled',
                          valueColor: _gateAccess!.isActive ? AppTheme.success : AppTheme.error,
                        ),
                        if (_gateAccess!.createdAt != null)
                          _buildInfoItem(
                            context,
                            icon: Icons.calendar_today_outlined,
                            label: 'Created',
                            value: _formatDateTime(_gateAccess!.createdAt),
                          ),
                        if (_gateAccess!.updatedAt != null)
                          _buildInfoItem(
                            context,
                            icon: Icons.update,
                            label: 'Last Updated',
                            value: _formatDateTime(_gateAccess!.updatedAt),
                          ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _toggleGateAccess,
                            icon: Icon(_gateAccess!.isActive ? Icons.block : Icons.check),
                            label: Text(_gateAccess!.isActive ? 'Disable Access' : 'Enable Access'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _gateAccess!.isActive ? AppTheme.error : AppTheme.success,
                              foregroundColor: AppTheme.textOnDark,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                      ] else ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            'No gate access code assigned',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader(context, Icons.notes_outlined, 'Notes', onEdit: () => _editNotes(tenant)),
                      const SizedBox(height: 8),
                      tenant.notes != null && tenant.notes!.isNotEmpty
                          ? Text(tenant.notes!)
                          : _buildPlaceholder(context, 'No notes on file.'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _buildContractsSection(context, tenant),
              const SizedBox(height: 16),
              _buildInsuranceSection(context, tenant),
              const SizedBox(height: 24),
            ],
          ),
    );
  }

  static void _showArchiveDialog(BuildContext context, TenantModel tenant) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Archive Tenant'),
        content: Text('Are you sure you want to archive ${tenant.name}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              
              try {
                await TenantService.archiveTenant(
                  facilityId: tenant.facilityId,
                  tenantId: tenant.id!,
                );
                
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Tenant archived successfully'),
                      backgroundColor: AppTheme.success,
                    ),
                  );
                  // Navigate back to avoid showing archived tenant
                  Navigator.of(context).pop();
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error archiving tenant: $e'),
                      backgroundColor: AppTheme.error,
                    ),
                  );
                }
              }
            },
            child: const Text('Archive'),
          ),
        ],
      ),
    );
  }

  static void _showDeleteDialog(BuildContext context, TenantModel tenant) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Tenant'),
        content: Text('Are you sure you want to permanently delete ${tenant.name}? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              
              try {
                await TenantService.deleteTenant(
                  facilityId: tenant.facilityId,
                  tenantId: tenant.id!,
                );
                
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Tenant deleted successfully'),
                      backgroundColor: AppTheme.success,
                    ),
                  );
                  // Navigate back since tenant no longer exists
                  Navigator.of(context).pop();
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error deleting tenant: $e'),
                      backgroundColor: AppTheme.error,
                    ),
                  );
                }
              }
            },
            child: Text('Delete', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
  }

  void _showMarkPaidDialog(BuildContext context, TenantModel tenant) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mark Payment as Paid'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Mark ${tenant.name} as paid through the end of this month?'),
            const SizedBox(height: 16),
            const Text(
              'This will:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const Text('• Create a payment record'),
            const Text('• Update paidThrough date'),
            const Text('• Clear the late status'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await _markTenantAsPaid(context, tenant);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.success,
              foregroundColor: AppTheme.textOnDark,
            ),
            child: const Text('Mark Paid'),
          ),
        ],
      ),
    );
  }

  Future<void> _markTenantAsPaid(BuildContext context, TenantModel tenant) async {
    try {
      // Use the PaymentService to mark tenant as paid
      await ref.read(paymentOperationsProvider.notifier).markTenantAsPaid(
        facilityId: tenant.facilityId,
        tenantId: tenant.id,
        amount: tenant.monthlyRate,
        method: PaymentMethod.cash,
        notes: 'Marked as paid manually',
      );

      // Invalidate providers to refresh UI immediately
      ref.invalidate(facilityTenantsProvider(tenant.facilityId));
      ref.invalidate(paymentListProvider(tenant.facilityId));
      ref.invalidate(paymentStatsProvider(tenant.facilityId));

      // Calculate end of month for display
      final now = DateTime.now();
      final endOfMonth = DateTime(now.year, now.month + 1, 0);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${tenant.name} marked as paid through ${endOfMonth.month}/${endOfMonth.year}'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error marking payment: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _showEditPaidThroughDialog(TenantModel tenant) async {
    DateTime tempDate = tenant.paidThrough ?? DateTime.now();
    
    final result = await showDialog<DateTime?>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Set Paid Through Date'),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Set the month through which rent is paid:'),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: tempDate.month,
                            decoration: const InputDecoration(
                              labelText: 'Month',
                              border: OutlineInputBorder(),
                            ),
                            items: ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
                                .asMap()
                                .entries
                                .map((e) => DropdownMenuItem(value: e.key + 1, child: Text(e.value)))
                                .toList(),
                            onChanged: (value) {
                              if (value != null) {
                                setDialogState(() {
                                  tempDate = DateTime(tempDate.year, value, 1);
                                });
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: tempDate.year,
                            decoration: const InputDecoration(
                              labelText: 'Year',
                              border: OutlineInputBorder(),
                            ),
                            items: List.generate(5, (i) => DateTime.now().year - 1 + i)
                                .map((year) => DropdownMenuItem(value: year, child: Text('$year')))
                                .toList(),
                            onChanged: (value) {
                              if (value != null) {
                                setDialogState(() {
                                  tempDate = DateTime(value, tempDate.month, 1);
                                });
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, DateTime(1970, 1, 1)),
                  child: const Text('Clear (Not Paid)'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(dialogContext, tempDate),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null) return;

    try {
      final DateTime? dateToSet = (result.year == 1970) ? null : result;
      
      await TenantService.updateTenant(
        facilityId: tenant.facilityId,
        tenantId: tenant.id,
        paidThrough: dateToSet,
        clearPaidThrough: dateToSet == null,
      );

      if (mounted) {
        // Refresh tenant list
        ref.invalidate(facilityTenantsProvider(tenant.facilityId));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(dateToSet == null ? 'Paid Through cleared' : 'Paid Through updated'), backgroundColor: AppTheme.success),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  void _showMarkLateDialog(BuildContext context, TenantModel tenant) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mark Tenant as Late'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Mark ${tenant.name} as late?'),
            const SizedBox(height: 16),
            const Text(
              'This will:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const Text('• Clear the paidThrough date'),
            const Text('• Mark tenant as late on payments'),
            const Text('• Tenant will appear in late payment reports'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await _markTenantAsLate(context, tenant);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.warning,
              foregroundColor: AppTheme.textOnDark,
            ),
            child: const Text('Mark as Late'),
          ),
        ],
      ),
    );
  }

  Future<void> _markTenantAsLate(BuildContext context, TenantModel tenant) async {
    try {
      await TenantService.markTenantAsLate(
        facilityId: tenant.facilityId,
        tenantId: tenant.id,
        paidThroughDate: null, // Set to null to make tenant late
      );

      // Invalidate providers to refresh UI immediately
      ref.invalidate(facilityTenantsProvider(tenant.facilityId));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${tenant.name} marked as late'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error marking tenant as late: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _sendQuickReminder(TenantModel tenant) async {
    try {
      if (tenant.email == null || tenant.email!.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Tenant has no email address on file'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
        return;
      }

      // Create a reminder
      final reminder = await ReminderService.createReminder(
        facilityId: tenant.facilityId,
        tenantId: tenant.id,
        type: ReminderType.custom,
        title: 'Payment Reminder',
        message: 'This is a reminder about your storage unit. Please contact us if you have any questions.',
        scheduledFor: DateTime.now(),
        channels: [ReminderChannel.email],
        tenantEmail: tenant.email,
        tenantPhone: tenant.phone,
      );

      // Send reminder immediately
      final sent = await ReminderService.sendReminder(
        facilityId: tenant.facilityId,
        reminderId: reminder.id,
        tenantEmail: tenant.email ?? '',
        tenantPhone: tenant.phone ?? '',
        message: 'This is a reminder about your storage unit. Please contact us if you have any questions.',
        channels: [ReminderChannel.email],
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(sent ? 'Reminder email sent successfully' : 'Failed to send reminder email'),
            backgroundColor: sent ? AppTheme.success : AppTheme.error,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error sending reminder: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  void _showQuickMessageSheet(TenantModel tenant) {
    final smsAvailable = tenant.phone.isNotEmpty;
    final emailAvailable = tenant.email.isNotEmpty;
    bool sendSMS = smsAvailable;
    bool sendEmail = emailAvailable && !smsAvailable; // default: pick one channel
    final messageController = TextEditingController(text: 'This is a quick message regarding your unit.');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            left: 16,
            right: 16,
            top: 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.flash_on),
                  const SizedBox(width: 8),
                  Text(
                    'Quick Message',
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              material.SwitchListTile.adaptive(
                value: sendSMS,
                onChanged: smsAvailable
                        ? (v) => setModalState(() {
                          sendSMS = v;
                        })
                    : null,
                title: const Text('Send SMS'),
                subtitle: Text(smsAvailable ? 'To ${tenant.phone}' : 'No phone on file'),
              ),
              material.SwitchListTile.adaptive(
                value: sendEmail,
                onChanged: emailAvailable
                        ? (v) => setModalState(() {
                          sendEmail = v;
                        })
                    : null,
                title: const Text('Send Email'),
                subtitle: Text(emailAvailable ? 'To ${tenant.email}' : 'No email on file'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: messageController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Message',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: (!sendSMS && !sendEmail)
                        ? null
                        : () async {
                            Navigator.of(ctx).pop();
                            await _sendQuickMessage(tenant, messageController.text.trim(), sendSMS, sendEmail);
                          },
                    icon: const Icon(Icons.send),
                    label: const Text('Send'),
                  ),
                ],
              ),
            ],
          ),
            );
          },
        );
      },
    );
  }

  Future<void> _sendQuickMessage(
    TenantModel tenant,
    String message,
    bool sendSMS,
    bool sendEmail,
  ) async {
    if (message.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please enter a message'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
      return;
    }

    // Show loading
    ScaffoldMessengerState? messenger;
    if (mounted) {
      messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.textOnDark),
              ),
              SizedBox(width: 16),
              Text('Sending message...'),
            ],
          ),
          duration: Duration(seconds: 30),
        ),
      );
    }

    final channels = <ReminderChannel>[];
    if (sendSMS && tenant.phone.isNotEmpty) channels.add(ReminderChannel.sms);
    if (sendEmail && tenant.email.isNotEmpty) channels.add(ReminderChannel.email);

    if (channels.isEmpty) {
      if (mounted && messenger != null) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(
            content: Text('No valid contact method selected'),
            backgroundColor: AppTheme.warning,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    try {
      final reminder = await ReminderService.createReminder(
        facilityId: tenant.facilityId,
        tenantId: tenant.id,
        type: ReminderType.custom,
        title: 'Quick Message',
        message: message,
        scheduledFor: DateTime.now(),
        channels: channels,
        tenantEmail: tenant.email,
        tenantPhone: tenant.phone,
      );

      final sent = await ReminderService.sendReminder(
        facilityId: tenant.facilityId,
        reminderId: reminder.id,
        tenantEmail: tenant.email ?? '',
        tenantPhone: tenant.phone ?? '',
        message: message,
        channels: channels,
      );

      if (mounted && messenger != null) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            content: Text(sent ? 'Message sent successfully' : 'Failed to send message'),
            backgroundColor: sent ? AppTheme.success : AppTheme.error,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted && messenger != null) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            content: Text('Error sending message: ${e.toString()}'),
            backgroundColor: AppTheme.error,
            duration: const Duration(seconds: 5),
          ),
        );
      }
      if (kDebugMode) {
        print('❌ Error sending quick message: $e');
      }
    }
  }

  String _getMonthStatus(TenantModel tenant, DateTime month) {
    final yyyyMM = '${month.year}-${month.month.toString().padLeft(2, '0')}';
    final override = tenant.monthStatusOverrides[yyyyMM];
    if (override != null && override.isNotEmpty) return override;
    final pt = tenant.paidThrough;
    if (pt == null) return 'late';
    final isPaid = month.year < pt.year || (month.year == pt.year && month.month <= pt.month);
    return isPaid ? 'paid' : 'late';
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'paid': return AppTheme.success;
      case 'late': return AppTheme.error;
      case 'moved_out': return AppTheme.warning;
      default: return AppTheme.textSecondary;
    }
  }

  Future<void> _setMonthStatus(TenantModel tenant, DateTime month, String? status) async {
    if (_isSavingMonthStatus) return;
    final yyyyMM = '${month.year}-${month.month.toString().padLeft(2, '0')}';
    setState(() => _isSavingMonthStatus = true);
    try {
      await TenantService.updateTenantMonthStatus(
        facilityId: tenant.facilityId,
        tenantId: tenant.id,
        yearMonth: yyyyMM,
        status: status,
      );
      final newOverrides = Map<String, String>.from(tenant.monthStatusOverrides);
      if (status != null) {
        newOverrides[yyyyMM] = status;
      } else {
        newOverrides.remove(yyyyMM);
      }
      if (mounted) setState(() {
        _tenantOverride = tenant.copyWith(monthStatusOverrides: newOverrides);
        _isSavingMonthStatus = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update: $e')),
        );
        setState(() => _isSavingMonthStatus = false);
      }
    }
  }

  void _showMonthStatusPicker(TenantModel tenant, DateTime month) {
    final currentStatus = _getMonthStatus(tenant, month);
    final monthLabel = DateFormat('MMMM yyyy').format(month);
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Set status for $monthLabel',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              _monthStatusOption(ctx, tenant, month, 'paid', 'Paid', Icons.check_circle, AppTheme.success, currentStatus),
              _monthStatusOption(ctx, tenant, month, 'late', 'Late', Icons.warning, AppTheme.error, currentStatus),
              _monthStatusOption(ctx, tenant, month, 'moved_out', 'Moved Out', Icons.exit_to_app, AppTheme.warning, currentStatus),
              if (tenant.monthStatusOverrides.containsKey('${month.year}-${month.month.toString().padLeft(2, '0')}'))
                _monthStatusOption(ctx, tenant, month, null, 'Clear override (use auto)', Icons.refresh, AppTheme.textSecondary, currentStatus),
            ],
          ),
        ),
      ),
    );
  }

  Widget _monthStatusOption(BuildContext ctx, TenantModel tenant, DateTime month, String? status, String label, IconData icon, Color color, String currentStatus) {
    final yyyyMM = '${month.year}-${month.month.toString().padLeft(2, '0')}';
    final isOverride = tenant.monthStatusOverrides.containsKey(yyyyMM);
    final isSelected = status == null ? !isOverride : (status == currentStatus);
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label),
      trailing: isSelected ? const Icon(Icons.check) : null,
      onTap: () async {
        Navigator.pop(ctx);
        await _setMonthStatus(tenant, month, status);
      },
    );
  }

  Widget _buildPaymentHistorySummary(TenantModel tenant) {
    final ledgerParams = LedgerParams(tenantId: tenant.id!, facilityId: tenant.facilityId);
    final ledgerAsync = ref.watch(ledgerStreamProvider(ledgerParams));
    final now = DateTime.now();
    final months = List<DateTime>.generate(12, (i) {
      final d = DateTime(now.year, now.month - (11 - i), 1);
      return d;
    });
    return ledgerAsync.when(
      data: (entries) {
        final paymentEntries = entries.where((e) =>
          e.status != LedgerEntryStatus.voided &&
          (e.type == LedgerEntryType.payment ||
           e.type == LedgerEntryType.credit ||
           e.type == LedgerEntryType.refund)).toList();
        final paymentCount = paymentEntries.length;
        var paidMonths = 0;
        var lateMonths = 0;
        var movedOutMonths = 0;
        for (final m in months) {
          final s = _getMonthStatus(tenant, m);
          if (s == 'paid') paidMonths++;
          else if (s == 'late') lateMonths++;
          else if (s == 'moved_out') movedOutMonths++;
        }
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
                children: [
                  Icon(Icons.payment_outlined, size: 18, color: AppTheme.primaryBlue),
                  const SizedBox(width: 8),
                  Text(
                    'Payment History',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: AppTheme.primaryBlue,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  _summaryChip('Payments made', '$paymentCount', Icons.check_circle_outline, AppTheme.success),
                  _summaryChip('Paid', '$paidMonths', Icons.calendar_today, AppTheme.success),
                  _summaryChip('Late', '$lateMonths', Icons.calendar_today, lateMonths > 0 ? AppTheme.error : AppTheme.textSecondary),
                  _summaryChip('Moved out', '$movedOutMonths', Icons.exit_to_app, movedOutMonths > 0 ? AppTheme.warning : AppTheme.textSecondary),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Click a month to set status (${DateFormat('MMM yyyy').format(months.first)} – ${DateFormat('MMM yyyy').format(months.last)}):',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: months.map((m) {
                  final status = _getMonthStatus(tenant, m);
                  final color = _statusColor(status);
                  return Material(
                    color: color.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(20),
                    child: InkWell(
                      onTap: _isSavingMonthStatus ? null : () => _showMonthStatusPicker(tenant, m),
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Text(
                          DateFormat('MMM yy').format(m),
                          style: TextStyle(
                            fontSize: 12,
                            color: color,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
      ),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _summaryChip(String label, String value, IconData icon, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(
          '$label: ',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
        ),
        Text(
          value,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _buildContractsSection(BuildContext context, TenantModel tenant) {
    final params = FacilityTenantParams(
      facilityId: tenant.facilityId,
      tenantId: tenant.id,
    );
    final contractsAsync = ref.watch(contractProv.tenantContractsProvider(params));

    Color _statusColor(ContractStatus s) {
      switch (s) {
        case ContractStatus.signed:   return AppTheme.success;
        case ContractStatus.sent:     return AppTheme.warning;
        case ContractStatus.expired:
        case ContractStatus.cancelled: return AppTheme.error;
        default:                      return AppTheme.textSecondary;
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _buildSectionHeader(context, Icons.description_outlined, 'Contracts'),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: () => context.push(
                    '${AppRoute.contractCreate}?facilityId=${tenant.facilityId}&tenantId=${tenant.id}',
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New Contract'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryBlueDark,
                    foregroundColor: AppTheme.textOnDark,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            contractsAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Text(
                'Could not load contracts.',
                style: TextStyle(color: AppTheme.error),
              ),
              data: (contracts) {
                if (contracts.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No contracts yet. Tap "New Contract" to create one.',
                      style: TextStyle(color: AppTheme.textSecondary),
                    ),
                  );
                }
                return Column(
                  children: contracts.map((c) {
                    final statusColor = _statusColor(c.status);
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.article_outlined,
                          color: AppTheme.primaryBlueDark),
                      title: Text(
                        c.title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: statusColor.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              c.status.displayName.toUpperCase(),
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: statusColor),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            c.type.displayName,
                            style: TextStyle(
                                fontSize: 12, color: AppTheme.textSecondary),
                          ),
                        ],
                      ),
                      trailing: TextButton(
                        onPressed: () => context.push(
                          AppRoute.contractDetail,
                          extra: c,
                        ),
                        child: const Text('View'),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInsuranceSection(BuildContext context, TenantModel tenant) {
    final theme = Theme.of(context);
    final status = tenant.insuranceStatus;
    final proofUrl = tenant.insuranceProofUrl;

    Color statusColor;
    String statusLabel;
    switch (status) {
      case InsuranceStatus.providedProof:
        statusColor = AppTheme.success;
        statusLabel = 'Proof Provided';
        break;
      case InsuranceStatus.enrolledInTPP:
        statusColor = AppTheme.success;
        statusLabel = 'Enrolled';
        break;
      case InsuranceStatus.pendingProof:
        statusColor = AppTheme.warning;
        statusLabel = 'Pending Proof';
        break;
      case InsuranceStatus.autoEnrolled:
        statusColor = AppTheme.warning;
        statusLabel = 'Auto-Enrolled';
        break;
      default:
        statusColor = AppTheme.textTertiary;
        statusLabel = 'None on File';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _buildSectionHeader(context, Icons.shield_outlined, 'Insurance'),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _showEditInsuranceDialog(context, tenant),
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Update'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Status badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: statusColor.withOpacity(0.1),
                border: Border.all(color: statusColor.withOpacity(0.4)),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                statusLabel,
                style: TextStyle(fontSize: 13, color: statusColor, fontWeight: FontWeight.w600),
              ),
            ),
            if (tenant.insuranceProvider != null && tenant.insuranceProvider!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Provider: ${tenant.insuranceProvider}', style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: 12),
            // Proof document row
            if (proofUrl != null && proofUrl.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.success.withOpacity(0.06),
                  border: Border.all(color: AppTheme.success.withOpacity(0.3)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.insert_drive_file_outlined, color: AppTheme.success, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Proof document on file',
                        style: theme.textTheme.bodyMedium?.copyWith(color: AppTheme.success, fontWeight: FontWeight.w600),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        final uri = Uri.tryParse(proofUrl);
                        if (uri != null && await canLaunchUrl(uri)) {
                          await launchUrl(uri, mode: LaunchMode.externalApplication);
                        }
                      },
                      icon: const Icon(Icons.open_in_new, size: 14),
                      label: const Text('View'),
                      style: TextButton.styleFrom(foregroundColor: AppTheme.success),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.error),
                      tooltip: 'Remove proof document',
                      onPressed: () => _removeInsuranceProof(tenant),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            // Upload button
            OutlinedButton.icon(
              onPressed: () => _uploadInsuranceProof(tenant),
              icon: const Icon(Icons.upload_file_outlined, size: 18),
              label: Text(proofUrl != null && proofUrl.isNotEmpty ? 'Replace Document' : 'Upload Proof Document'),
            ),
            if (status == InsuranceStatus.none && (proofUrl == null || proofUrl.isEmpty)) ...[
              const SizedBox(height: 6),
              Text(
                'Upload an image or PDF of their insurance card or policy.',
                style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _uploadInsuranceProof(TenantModel tenant) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf', 'heic', 'webp'],
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.bytes == null || file.bytes!.isEmpty) return;

    // Show uploading indicator
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(children: [
          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
          SizedBox(width: 12),
          Text('Uploading insurance proof…'),
        ]),
        duration: Duration(seconds: 30),
        behavior: SnackBarBehavior.floating,
      ),
    );

    try {
      final ext = file.name.split('.').last.toLowerCase();
      final path = 'facilities/${tenant.facilityId}/tenants/${tenant.id}/insurance_proof_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final storageRef = FirebaseStorage.instance.ref().child(path);
      final contentType = (ext == 'pdf') ? 'application/pdf' : 'image/$ext';
      await storageRef.putData(file.bytes!, SettableMetadata(contentType: contentType));
      final downloadUrl = await storageRef.getDownloadURL();

      await TenantService.updateTenant(
        facilityId: tenant.facilityId,
        tenantId: tenant.id,
        insuranceProofUrl: downloadUrl,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Insurance proof uploaded.'), behavior: SnackBarBehavior.floating, backgroundColor: AppTheme.success),
      );
      ref.invalidate(facilityTenantsProvider(tenant.facilityId));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Upload failed: $e'), behavior: SnackBarBehavior.floating, backgroundColor: AppTheme.error),
      );
    }
  }

  Future<void> _removeInsuranceProof(TenantModel tenant) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Proof Document'),
        content: const Text('Are you sure you want to remove the insurance proof document?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await TenantService.updateTenant(
        facilityId: tenant.facilityId,
        tenantId: tenant.id,
        clearInsuranceProofUrl: true,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Proof document removed.'), behavior: SnackBarBehavior.floating),
      );
      ref.invalidate(facilityTenantsProvider(tenant.facilityId));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), behavior: SnackBarBehavior.floating, backgroundColor: AppTheme.error),
      );
    }
  }

  Future<void> _showEditInsuranceDialog(BuildContext context, TenantModel tenant) async {
    InsuranceStatus selectedStatus = tenant.insuranceStatus;
    final providerController = TextEditingController(text: tenant.insuranceProvider ?? '');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Update Insurance Status'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Status'),
              const SizedBox(height: 8),
              DropdownButtonFormField<InsuranceStatus>(
                value: selectedStatus,
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                items: const [
                  DropdownMenuItem(value: InsuranceStatus.none, child: Text('None on File')),
                  DropdownMenuItem(value: InsuranceStatus.pendingProof, child: Text('Pending Proof')),
                  DropdownMenuItem(value: InsuranceStatus.providedProof, child: Text('Proof Provided')),
                  DropdownMenuItem(value: InsuranceStatus.enrolledInTPP, child: Text('Enrolled')),
                ],
                onChanged: (v) => setDialogState(() => selectedStatus = v ?? InsuranceStatus.none),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: providerController,
                decoration: const InputDecoration(
                  labelText: 'Provider Name (optional)',
                  border: OutlineInputBorder(),
                  isDense: true,
                  hintText: 'e.g. StorSmart Insurance',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await TenantService.updateTenant(
        facilityId: tenant.facilityId,
        tenantId: tenant.id,
        insuranceStatus: selectedStatus,
        insuranceProvider: providerController.text.trim().isEmpty ? null : providerController.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Insurance status updated.'), behavior: SnackBarBehavior.floating),
      );
      ref.invalidate(facilityTenantsProvider(tenant.facilityId));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error updating insurance: $e'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppTheme.error,
        ),
      );
    }
  }

  Widget _buildSectionHeader(BuildContext context, IconData icon, String title, {VoidCallback? onEdit}) {
    final color = Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        Icon(icon, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, color: color),
          ),
        ),
        if (onEdit != null)
          IconButton(
            onPressed: onEdit,
            icon: const Icon(Icons.edit, size: 18),
            tooltip: 'Edit $title',
            color: color,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
      ],
    );
  }

  Widget _buildInfoItem(BuildContext context,
      {required IconData icon, required String label, required String value, Color? valueColor, VoidCallback? onEdit}) {
    final textTheme = Theme.of(context).textTheme;
    final color = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: AppTheme.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(value, style: textTheme.bodyMedium?.copyWith(color: valueColor ?? AppTheme.textTertiary)),
              ],
            ),
          ),
          if (onEdit != null)
            IconButton(
              onPressed: onEdit,
              icon: const Icon(Icons.edit, size: 16),
              tooltip: 'Edit $label',
              color: color,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder(BuildContext context, String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary),
      ),
    );
  }

  String _valueOrPlaceholder(String? value, {String fallback = 'Not provided'}) {
    if (value == null || value.trim().isEmpty) {
      return fallback;
    }
    return value.trim();
  }

  String _formatCurrency(double amount) {
    return '\$${amount.toStringAsFixed(2)}';
  }

}

// ── Helper classes for edit mode ────────────────────────────────────────────

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
