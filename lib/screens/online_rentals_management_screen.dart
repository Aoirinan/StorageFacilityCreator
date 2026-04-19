import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
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
import '../utils/renter_account_message.dart';

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
  List<FacilityModel> _userFacilities = const <FacilityModel>[];

  final TextEditingController _slugController = TextEditingController();
  final TextEditingController _customDomainController = TextEditingController();
  final TextEditingController _marketingContentController =
      TextEditingController();
  final TextEditingController _logoUrlController = TextEditingController();
  final TextEditingController _insuranceAmountController =
      TextEditingController();
  final TextEditingController _securityDepositAmountController =
      TextEditingController();
  bool _publicRentalsEnabled = false;
  bool _publicPricingEnabled = true;
  bool _publicUnitNumbersEnabled = true;
  bool _allowAutoAssign = true;
  bool _allowUnitSelection = true;
  bool _showAvailabilityCount = true;
  bool _hideUnavailableTypes = true;
  bool _chargeNextMonthAfterMidMonthMoveIn = false;
  bool _chargeInsuranceAtMoveIn = false;
  bool _chargeSecurityDepositAtMoveIn = false;
  Set<String> _enabledPublicUnitTypes = <String>{};
  Set<String> _availableUnitTypes = <String>{};
  Map<String, String> _unitTypeImageUrls = <String, String>{};
  bool _isUploadingLogo = false;
  String? _uploadingUnitType;
  bool _isCheckingDomain = false;
  bool? _domainConnected;
  String? _domainCheckMessage;
  List<String> _domainRecords = const <String>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant OnlineRentalsManagementScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.facilityId != widget.facilityId) {
      _load();
    }
  }

  @override
  void dispose() {
    _slugController.dispose();
    _customDomainController.dispose();
    _marketingContentController.dispose();
    _logoUrlController.dispose();
    _insuranceAmountController.dispose();
    _securityDepositAmountController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final facilities = await FacilityService.getUserFacilities();
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
        _userFacilities = facilities;
        _publicRentalsEnabled = settings?.publicRentalsEnabled ?? false;
        _publicPricingEnabled = settings?.publicPricingEnabled ?? true;
        _publicUnitNumbersEnabled = settings?.publicUnitNumbersEnabled ?? true;
        _allowAutoAssign = settings?.allowAutoAssign ?? true;
        _allowUnitSelection = settings?.allowUnitSelection ?? true;
        _showAvailabilityCount = settings?.showAvailabilityCount ?? true;
        _hideUnavailableTypes = settings?.hideUnavailableTypes ?? true;
        _chargeNextMonthAfterMidMonthMoveIn =
            settings?.chargeNextMonthAfterMidMonthMoveIn ?? false;
        _chargeInsuranceAtMoveIn = settings?.chargeInsuranceAtMoveIn ?? false;
        _chargeSecurityDepositAtMoveIn =
            settings?.chargeSecurityDepositAtMoveIn ?? false;
        _enabledPublicUnitTypes =
            settings?.enabledPublicUnitTypes.toSet() ?? <String>{};
        _availableUnitTypes = types;
        _unitTypeImageUrls = settings?.unitTypeImageUrls ?? <String, String>{};
        _customDomainController.text = settings?.customDomain ?? '';
        _marketingContentController.text =
            settings?.marketingContent ?? settings?.pageDescription ?? '';
        _logoUrlController.text = settings?.publicLogoUrl ?? '';
        _insuranceAmountController.text =
            (settings?.publicInsuranceAmount ?? 0) > 0
                ? (settings!.publicInsuranceAmount!).toStringAsFixed(2)
                : '';
        _securityDepositAmountController.text =
            (settings?.publicSecurityDepositAmount ?? 0) > 0
                ? (settings!.publicSecurityDepositAmount!).toStringAsFixed(2)
                : '';
        _slugController.text =
            (settings?.publicRentalSlug?.trim().isNotEmpty ?? false)
                ? settings!.publicRentalSlug!
                : (publicSlug ?? widget.facilityId.toLowerCase());
        _isLoading = false;
      });
      if (_customDomainController.text.trim().isNotEmpty) {
        unawaited(_checkDomainStatus());
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load online rental settings: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _save() async {
    final slug = normalizePublicRentalSlug(_slugController.text);
    final customDomain = normalizeCustomDomain(_customDomainController.text);
    final marketingContent = _marketingContentController.text.trim();
    final logoUrl = _logoUrlController.text.trim();
    final insuranceAmount =
        double.tryParse(_insuranceAmountController.text.trim()) ?? 0;
    final securityDepositAmount =
        double.tryParse(_securityDepositAmountController.text.trim()) ?? 0;
    if (slug.isEmpty) {
      setState(() {
        _error = 'Please enter a valid public URL name.';
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
        chargeNextMonthAfterMidMonthMoveIn: _chargeNextMonthAfterMidMonthMoveIn,
        chargeInsuranceAtMoveIn: _chargeInsuranceAtMoveIn,
        publicInsuranceAmount: insuranceAmount > 0 ? insuranceAmount : null,
        chargeSecurityDepositAtMoveIn: _chargeSecurityDepositAtMoveIn,
        publicSecurityDepositAmount:
            securityDepositAmount > 0 ? securityDepositAmount : null,
        enabledPublicUnitTypes: _enabledPublicUnitTypes.toList(),
        publicRentalSlug: slug,
        customDomain: customDomain.isEmpty ? null : customDomain,
        marketingContent: marketingContent.isEmpty ? null : marketingContent,
        publicLogoUrl: logoUrl.isEmpty ? null : logoUrl,
        unitTypeImageUrls:
            _unitTypeImageUrls.isEmpty ? null : _unitTypeImageUrls,
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

  String get _linkBaseUrl {
    return linkBaseUrlFromCustomDomainField(_customDomainController.text);
  }

  Future<void> _checkDomainStatus({bool showSnackBar = false}) async {
    final domain = normalizeCustomDomain(_customDomainController.text);
    if (domain.isEmpty) {
      setState(() {
        _domainConnected = null;
        _domainCheckMessage = null;
        _domainRecords = const <String>[];
      });
      return;
    }
    setState(() {
      _isCheckingDomain = true;
      _domainCheckMessage = null;
      _domainRecords = const <String>[];
    });
    final result = await FacilityPublicService.verifyCustomDomain(domain);
    if (!mounted) return;
    setState(() {
      _isCheckingDomain = false;
      _domainConnected = result.isConnected;
      _domainCheckMessage = result.message;
      _domainRecords = result.records;
    });
    if (showSnackBar) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.message),
          backgroundColor:
              result.isConnected ? AppTheme.success : AppTheme.warning,
        ),
      );
    }
  }

  Future<void> _uploadLogo() async {
    setState(() {
      _isUploadingLogo = true;
      _error = null;
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'svg'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        setState(() => _isUploadingLogo = false);
        return;
      }
      final file = result.files.first;
      if (file.bytes == null) {
        throw Exception('Unable to read selected image data.');
      }
      final ext = (file.extension ?? 'png').toLowerCase();
      final contentType = switch (ext) {
        'jpg' || 'jpeg' => 'image/jpeg',
        'webp' => 'image/webp',
        'svg' => 'image/svg+xml',
        _ => 'image/png',
      };
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final safeName = file.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final path =
          'facilities/${widget.facilityId}/public-branding/logo-$stamp-$safeName';
      final ref = FirebaseStorage.instance.ref(path);
      await ref.putData(
          file.bytes!, SettableMetadata(contentType: contentType));
      final url = await ref.getDownloadURL();
      if (!mounted) return;
      setState(() {
        _logoUrlController.text = url;
        _isUploadingLogo = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isUploadingLogo = false;
        _error = 'Logo upload failed: $e';
      });
    }
  }

  String get _slugPreview {
    final slug = normalizePublicRentalSlug(_slugController.text);
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

  String _buildRenterAccountMessage() {
    return buildRenterAccountMessage(
      facility: _facility,
      slug: _slugPreview,
      linkBaseUrl: _linkBaseUrl,
    );
  }

  Future<void> _copyRenterAccountMessage() async {
    await Clipboard.setData(ClipboardData(text: _buildRenterAccountMessage()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Renter message copied — replace [AMOUNT] and [PAYMENT_LINK]'),
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

  String _normalizeUnitTypeKey(String raw) {
    return raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }

  String _activePricingPresetId() {
    final minimal = !_chargeNextMonthAfterMidMonthMoveIn &&
        !_chargeInsuranceAtMoveIn &&
        !_chargeSecurityDepositAtMoveIn;
    if (minimal) return 'minimal';

    final standard = !_chargeNextMonthAfterMidMonthMoveIn &&
        !_chargeInsuranceAtMoveIn &&
        _chargeSecurityDepositAtMoveIn;
    if (standard) return 'standard';

    final full = _chargeNextMonthAfterMidMonthMoveIn &&
        _chargeInsuranceAtMoveIn &&
        _chargeSecurityDepositAtMoveIn;
    if (full) return 'full';

    return 'custom';
  }

  void _applyPricingPreset(String presetId) {
    setState(() {
      switch (presetId) {
        case 'minimal':
          _chargeNextMonthAfterMidMonthMoveIn = false;
          _chargeInsuranceAtMoveIn = false;
          _chargeSecurityDepositAtMoveIn = false;
          break;
        case 'standard':
          _chargeNextMonthAfterMidMonthMoveIn = false;
          _chargeInsuranceAtMoveIn = false;
          _chargeSecurityDepositAtMoveIn = true;
          break;
        case 'full':
          _chargeNextMonthAfterMidMonthMoveIn = true;
          _chargeInsuranceAtMoveIn = true;
          _chargeSecurityDepositAtMoveIn = true;
          break;
      }
    });
  }

  Future<void> _uploadUnitTypeImage(String unitType) async {
    setState(() {
      _uploadingUnitType = unitType;
      _error = null;
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        setState(() => _uploadingUnitType = null);
        return;
      }
      final file = result.files.first;
      if (file.bytes == null) {
        throw Exception('Unable to read selected image data.');
      }

      final ext = (file.extension ?? 'png').toLowerCase();
      final contentType = switch (ext) {
        'jpg' || 'jpeg' => 'image/jpeg',
        'webp' => 'image/webp',
        _ => 'image/png',
      };
      final safeType = _normalizeUnitTypeKey(unitType);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final safeName = file.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final path =
          'facilities/${widget.facilityId}/public-branding/unit-types/$safeType-$stamp-$safeName';
      final ref = FirebaseStorage.instance.ref(path);
      await ref.putData(
          file.bytes!, SettableMetadata(contentType: contentType));
      final url = await ref.getDownloadURL();

      if (!mounted) return;
      setState(() {
        _unitTypeImageUrls[safeType] = url;
        _uploadingUnitType = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploadingUnitType = null;
        _error = 'Unit type image upload failed: $e';
      });
    }
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
        if (_userFacilities.length > 1) ...[
          DropdownButtonFormField<String>(
            value: widget.facilityId,
            decoration: const InputDecoration(
              labelText: 'Facility',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.apartment),
            ),
            items: _userFacilities
                .map(
                  (f) => DropdownMenuItem<String>(
                    value: f.id,
                    child: Text(f.name),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value == null || value == widget.facilityId) {
                return;
              }
              context.go('/online-rentals?facilityId=$value');
            },
          ),
          const SizedBox(height: 12),
        ],
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
          controller: _customDomainController,
          onChanged: (_) {
            setState(() {
              _domainConnected = null;
              _domainCheckMessage = null;
              _domainRecords = const <String>[];
            });
          },
          decoration: const InputDecoration(
            labelText: 'Custom Domain (optional)',
            hintText: 'rent.yourfacility.com',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.language),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _isCheckingDomain
                  ? null
                  : () => _checkDomainStatus(showSnackBar: true),
              icon: _isCheckingDomain
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_tethering),
              label: Text(_isCheckingDomain
                  ? 'Checking...'
                  : 'Check Domain Connection'),
            ),
            const SizedBox(width: 10),
            if (_domainConnected != null)
              _DomainStatusChip(connected: _domainConnected!),
          ],
        ),
        if (_domainCheckMessage != null) ...[
          const SizedBox(height: 6),
          Text(
            _domainCheckMessage!,
            style: TextStyle(
              color: _domainConnected == true
                  ? AppTheme.success
                  : AppTheme.warning,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        if (_domainRecords.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            'DNS records: ${_domainRecords.join(', ')}',
            style: const TextStyle(
              fontSize: 12,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _marketingContentController,
          maxLines: 4,
          minLines: 3,
          decoration: const InputDecoration(
            labelText: 'Public Marketing Text',
            hintText:
                'Write anything you want renters to see on your rental page.',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
            prefixIcon: Icon(Icons.edit_note),
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFF),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFE2E8F5)),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Page Suggestions',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              SizedBox(height: 6),
              Text('- Add one clear headline with city/location'),
              Text('- Use 1-2 short trust paragraphs'),
              Text('- Upload images for each unit type'),
              Text('- Keep FAQs practical and short'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _logoUrlController,
          decoration: InputDecoration(
            labelText: 'Public Logo URL',
            hintText: 'https://...',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.image),
            suffixIcon: _isUploadingLogo
                ? const Padding(
                    padding: EdgeInsets.all(10),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    tooltip: 'Upload Logo',
                    onPressed: _uploadLogo,
                    icon: const Icon(Icons.upload),
                  ),
          ),
        ),
        if (_logoUrlController.text.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 64),
              child: Image.network(
                _logoUrlController.text.trim(),
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _slugController,
          decoration: const InputDecoration(
            labelText: 'Public URL Name',
            hintText: 'your-facility',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.link),
          ),
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          value: _publicRentalsEnabled,
          onChanged: (v) => setState(() => _publicRentalsEnabled = v),
          title: const Text('Enable Public Online Rentals'),
        ),
        SwitchListTile(
          value: _publicPricingEnabled,
          onChanged: (v) => setState(() => _publicPricingEnabled = v),
          title: const Text('Show Pricing Publicly'),
        ),
        SwitchListTile(
          value: _publicUnitNumbersEnabled,
          onChanged: (v) => setState(() => _publicUnitNumbersEnabled = v),
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
          onChanged: (v) => setState(() => _showAvailabilityCount = v),
          title: const Text('Show Availability Count'),
        ),
        SwitchListTile(
          value: _hideUnavailableTypes,
          onChanged: (v) => setState(() => _hideUnavailableTypes = v),
          title: const Text('Hide Unavailable Types'),
        ),
        SwitchListTile(
          value: _chargeNextMonthAfterMidMonthMoveIn,
          onChanged: (v) =>
              setState(() => _chargeNextMonthAfterMidMonthMoveIn = v),
          title: const Text('After mid-month, also charge next month'),
          subtitle: const Text(
            'If move-in is after the halfway mark, charge prorated current month plus next month upfront.',
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Pricing Presets',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Apply a one-tap payment setup, then tweak if needed.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Minimal'),
                      selected: _activePricingPresetId() == 'minimal',
                      onSelected: (_) => _applyPricingPreset('minimal'),
                    ),
                    ChoiceChip(
                      label: const Text('Standard'),
                      selected: _activePricingPresetId() == 'standard',
                      onSelected: (_) => _applyPricingPreset('standard'),
                    ),
                    ChoiceChip(
                      label: const Text('Full'),
                      selected: _activePricingPresetId() == 'full',
                      onSelected: (_) => _applyPricingPreset('full'),
                    ),
                    if (_activePricingPresetId() == 'custom')
                      const Chip(
                        label: Text('Custom'),
                        avatar: Icon(Icons.tune, size: 16),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Minimal: prorate only | Standard: prorate + deposit | Full: prorate + next month + deposit + insurance',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
        SwitchListTile(
          value: _chargeInsuranceAtMoveIn,
          onChanged: (v) => setState(() => _chargeInsuranceAtMoveIn = v),
          title: const Text('Charge insurance at move-in'),
        ),
        if (_chargeInsuranceAtMoveIn)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _insuranceAmountController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Insurance Amount',
                prefixText: '\$',
                border: OutlineInputBorder(),
              ),
            ),
          ),
        SwitchListTile(
          value: _chargeSecurityDepositAtMoveIn,
          onChanged: (v) => setState(() => _chargeSecurityDepositAtMoveIn = v),
          title: const Text('Charge security deposit at move-in'),
          subtitle: const Text(
              'If no amount is set, unit or facility default deposit is used.'),
        ),
        if (_chargeSecurityDepositAtMoveIn)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _securityDepositAmountController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Security Deposit Amount (optional override)',
                prefixText: '\$',
                border: OutlineInputBorder(),
              ),
            ),
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
              final selected = _enabledPublicUnitTypes.contains(type);
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
        const SizedBox(height: 12),
        const Text(
          'Unit Type Photos',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        ...(() {
          final types = (_availableUnitTypes.isEmpty
                  ? UnitType.values.map((e) => e.name).toSet()
                  : _availableUnitTypes)
              .toList()
            ..sort();
          return types.map((type) {
            final key = _normalizeUnitTypeKey(type);
            final imageUrl = _unitTypeImageUrls[key];
            final uploading = _uploadingUnitType == type;
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: [
                    SizedBox(
                      width: 72,
                      height: 52,
                      child: imageUrl == null
                          ? Container(
                              color: const Color(0xFFF1F5F9),
                              child: const Icon(Icons.image_outlined),
                            )
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.network(
                                imageUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) =>
                                    const Icon(Icons.broken_image),
                              ),
                            ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _unitTypeLabel(type),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (uploading)
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    IconButton(
                      tooltip: 'Upload Photo',
                      onPressed:
                          uploading ? null : () => _uploadUnitTypeImage(type),
                      icon: const Icon(Icons.upload),
                    ),
                    if (imageUrl != null)
                      IconButton(
                        tooltip: 'Remove Photo',
                        onPressed: () {
                          setState(() {
                            _unitTypeImageUrls.remove(key);
                          });
                        },
                        icon: const Icon(Icons.delete_outline),
                      ),
                  ],
                ),
              ),
            );
          }).toList();
        })(),
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
                    _slugPreview,
                    baseUrl: _linkBaseUrl,
                  ),
                  onCopy: _copy,
                ),
                const Divider(),
                _LinkRow(
                  label: 'All Available Units Link',
                  value: FacilityPublicService.getPublicAvailableUnitsUrl(
                    _slugPreview,
                    baseUrl: _linkBaseUrl,
                  ),
                  onCopy: _copy,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Message for renters (SMS / email)',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Includes your public rent link, tenant portal (balance), and spots for the amount and secure pay link. Create the pay link under Payment Links, then paste it where shown.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 168),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _buildRenterAccountMessage(),
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.35,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _copyRenterAccountMessage,
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('Copy message'),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        context.push(
                          '/payment-links?facilityId=${widget.facilityId}',
                        );
                      },
                      icon: const Icon(Icons.payment, size: 18),
                      label: const Text('Payment Links'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: AppTheme.error)),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => context.push('/f/$_slugPreview/rent'),
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
                        child: CircularProgressIndicator(strokeWidth: 2),
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

class _DomainStatusChip extends StatelessWidget {
  final bool connected;

  const _DomainStatusChip({required this.connected});

  @override
  Widget build(BuildContext context) {
    final color = connected ? AppTheme.success : AppTheme.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        connected ? 'Looks Valid' : 'Needs Setup',
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }
}
