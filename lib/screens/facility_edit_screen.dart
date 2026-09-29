import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart' show FieldValue;
import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../providers/auth_provider.dart';
import '../router/app_route.dart';
import '../services/facility_service.dart';
import 'package:sfcapp/services/late_logic_service.dart';
import 'package:sfcapp/models/document_logo_layout.dart';
import 'package:sfcapp/models/security_deposit_model.dart';
import '../models/facility_model.dart';
import '../models/unit_model.dart';
import 'package:sfcapp/models/facility_public_settings_model.dart';
import '../theme/app_theme.dart';
import '../services/facility_map_v2_service.dart';
import '../services/facility_public_service.dart';
import 'package:sfcapp/services/unit_service.dart';
import '../utils/error_message_helper.dart';
import '../utils/time_zone_helper.dart';
import 'package:sfcapp/widgets/document_logo_layout_editor.dart';
import 'package:sfcapp/widgets/unit_numbers_repeat_setting.dart';
import '../constants/facility_capacity.dart';
import 'package:sfcapp/utils/save_then_publish.dart';

/// What Edit Facility reads and publishes besides the public settings doc,
/// which it reads and saves through [FacilityPublicService]. A provider, as
/// WebsiteSetupActions is for Website Setup, so widget tests can open the
/// real screen and run its real settings save against a fake Firestore.
class FacilityEditActions {
  const FacilityEditActions();

  Future<FacilityModel?> facility(String facilityId) =>
      FacilityService.getFacility(facilityId);

  /// The slug of the facility's published public map, if it has one.
  Future<String?> publishedSlug(String facilityId) =>
      FacilityMapV2Service.getPublicSlugForFacility(facilityId);

  /// Points the public map at [slug] and republishes it, which copies the
  /// saved settings into publicFacilityMaps/{slug}.
  Future<void> publish({
    required String facilityId,
    required String slug,
  }) async {
    await FacilityMapV2Service.setPublicSlug(facilityId: facilityId, slug: slug);
    await FacilityMapV2Service.publishCurrentDraft(facilityId: facilityId);
  }

  /// Whether the map published at [slug] has the website on.
  Future<bool> publishedWebsiteEnabled(String slug) =>
      FacilityMapV2Service.publishedWebsiteEnabled(slug);
}

final facilityEditActionsProvider =
    Provider<FacilityEditActions>((ref) => const FacilityEditActions());

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
  late final TextEditingController _mailingAddressController;
  late final TextEditingController _statementMessageController;
  late final TextEditingController _phoneController;
  late final TextEditingController _emailController;
  late final TextEditingController _gracePeriodController;
  late final TextEditingController _lateFeeAmountController;

  /// billingSettings.securityDeposit: the deposit usually taken at move-in,
  /// prefilled when one is recorded on a tenant. Blank means none.
  late final TextEditingController _securityDepositController;
  late final TextEditingController _totalUnitsController;

  String? _logoUrl;
  bool _isUploadingLogo = false;
  String? _logoError;

  /// Logo size/position/name-text on printed documents; saved with Update
  /// Facility like the logo itself.
  late DocumentLogoLayout _documentLogo;

  String? _selectedTimeZone;
  String _lateFeeType = 'flat';

  /// billingSettings.enableAutoLateFees. Off when the field is missing, as
  /// the delinquency job reads it: the fee above is only charged
  /// automatically once this is on.
  late bool _autoLateFees;

  bool _isLoading = false;
  String? _errorMessage;

  /// "Unit numbers repeat across areas", as the switch shows it. Saved only
  /// when it differs from the facility's.
  late bool _unitNumbersRepeat;

  /// Why the switch could not be turned off (units still share a number).
  String? _unitNumbersRepeatError;
  bool _checkingUnitNumbersRepeat = false;

  bool _isLoadingPublicSettings = true;
  // The rental form shows defaults until the saved settings load, and saving
  // those would switch rentals off and clear the unit types, so the form and
  // its save are hidden until then.
  bool _publicSettingsLoaded = false;
  bool _isSavingPublicSettings = false;
  String? _publicSettingsError;
  final TextEditingController _publicRentalSlugController =
      TextEditingController();
  bool _publicRentalsEnabled = false;
  bool _websiteEnabled = false;
  // Whether the facility has the website add-on. Starts from the facility
  // this screen opened with and is re-read on return from Website Setup,
  // where the add-on is bought.
  late bool _websiteEntitled = widget.facility.hasActiveWebsiteSubscription;
  // The slug as last read from the saved settings, so a return from Website
  // Setup can tell whether the slug was changed there.
  String? _savedSlug;
  // Whether the map published at [_savedSlug] has the website on: what
  // /w/{slug} serves, with the add-on. Null until read, or when the read
  // failed. The saved setting alone said "on" after a publish that failed.
  bool? _publishedWebsiteOn;
  bool _publishedWebsiteReadFailed = false;
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
    _mailingAddressController =
        TextEditingController(text: widget.facility.mailingAddress ?? '');
    _statementMessageController =
        TextEditingController(text: widget.facility.statementMessage ?? '');
    _logoUrl = widget.facility.logoUrl;
    _documentLogo = widget.facility.documentLogo;
    _phoneController = TextEditingController(text: widget.facility.phone ?? '');
    _emailController = TextEditingController(text: widget.facility.email ?? '');

    // Initialize billing settings
    final billingSettings = widget.facility.billingSettings;
    _autoLateFees = LateFeeRules.autoLateFeesEnabled(billingSettings);
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
    final defaultDeposit = SecurityDeposit.facilityDefault(billingSettings);
    _securityDepositController = TextEditingController(
      text: defaultDeposit == null ? '' : defaultDeposit.toStringAsFixed(2),
    );

    _totalUnitsController = TextEditingController(
      text: widget.facility.totalUnits > 0
          ? widget.facility.totalUnits.toString()
          : '',
    );
    _selectedTimeZone =
        widget.facility.timeZone ?? TimeZoneHelper.defaultTimeZoneId;
    _unitNumbersRepeat = widget.facility.unitNumbersRepeatAcrossAreas;
    _loadPublicRentalSettings();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _mailingAddressController.dispose();
    _statementMessageController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _gracePeriodController.dispose();
    _lateFeeAmountController.dispose();
    _securityDepositController.dispose();
    _totalUnitsController.dispose();
    _publicRentalSlugController.dispose();
    super.dispose();
  }

  Future<void> _loadPublicRentalSettings() async {
    setState(() {
      _isLoadingPublicSettings = true;
      _publicSettingsLoaded = false;
      _publicSettingsError = null;
    });
    try {
      // Both reads always run and neither needs the other, so run them
      // together instead of paying two round trips in series. Future.wait
      // also listens to both, so a failure in either lands in the catch below.
      final settingsFuture =
          FacilityPublicService.getPublicSettingsOrThrow(widget.facility.id);
      final mapSlugFuture = ref
          .read(facilityEditActionsProvider)
          .publishedSlug(widget.facility.id);
      await Future.wait([settingsFuture, mapSlugFuture]);
      final settings = await settingsFuture;
      final slug = settings.publicRentalSlug?.trim();
      final fallbackSlug =
          await mapSlugFuture ?? widget.facility.id.toLowerCase();
      final safeSlug = (slug == null || slug.isEmpty) ? fallbackSlug : slug;

      if (!mounted) return;
      setState(() {
        _publicRentalsEnabled = settings.publicRentalsEnabled;
        _websiteEnabled = settings.enabled;
        _publicPricingEnabled = settings.publicPricingEnabled;
        _publicUnitNumbersEnabled = settings.publicUnitNumbersEnabled;
        _allowAutoAssign = settings.allowAutoAssign;
        _allowUnitSelection = settings.allowUnitSelection;
        _showAvailabilityCount = settings.showAvailabilityCount;
        _hideUnavailableTypes = settings.hideUnavailableTypes;
        _enabledPublicUnitTypes = settings.enabledPublicUnitTypes.toSet();
        _publicRentalSlugController.text = safeSlug;
        _savedSlug = safeSlug;
        _publicSettingsLoaded = true;
        _isLoadingPublicSettings = false;
      });
      unawaited(_readPublishedWebsite());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _publicSettingsError = publicSettingsLoadErrorText(e);
        _isLoadingPublicSettings = false;
      });
    }
  }

  /// Reads whether the map published at [_savedSlug] has the website on, for
  /// [_buildWebsiteStatus].
  Future<void> _readPublishedWebsite() async {
    final slug = _savedSlug;
    if (slug == null) return;
    bool? on;
    try {
      on = await ref
          .read(facilityEditActionsProvider)
          .publishedWebsiteEnabled(slug);
    } catch (_) {
      on = null;
    }
    if (!mounted || _savedSlug != slug) return;
    setState(() {
      _publishedWebsiteOn = on;
      _publishedWebsiteReadFailed = on == null;
    });
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
    // Before the save, so a slug another facility holds is not kept in the
    // settings that rent links are built from.
    try {
      await FacilityMapV2Service.ensurePublicSlugAvailable(
          facilityId: widget.facility.id, slug: slug);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSavingPublicSettings = false;
        _publicSettingsError = ErrorMessageHelper.getUserFriendlyMessage(e);
      });
      return;
    }

    try {
      // As Website Setup saves: a failed publish says the settings were
      // saved, so the owner retries the publish rather than re-entering them.
      await saveThenPublish(
        save: () => FacilityPublicService.updateRentalSettings(
          facilityId: widget.facility.id,
          publicRentalsEnabled: _publicRentalsEnabled,
          publicPricingEnabled: _publicPricingEnabled,
          publicUnitNumbersEnabled: _publicUnitNumbersEnabled,
          allowAutoAssign: _allowAutoAssign,
          allowUnitSelection: _allowUnitSelection,
          showAvailabilityCount: _showAvailabilityCount,
          hideUnavailableTypes: _hideUnavailableTypes,
          enabledPublicUnitTypes: _enabledPublicUnitTypes.toList(),
          publicRentalSlug: slug,
        ),
        publish: () => ref
            .read(facilityEditActionsProvider)
            .publish(facilityId: widget.facility.id, slug: slug),
      );

      if (!mounted) return;
      setState(() {
        _publicRentalSlugController.text = slug;
        _savedSlug = slug;
        _isSavingPublicSettings = false;
      });
      unawaited(_readPublishedWebsite());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Public rental links saved and published.'),
          backgroundColor: AppTheme.success,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (e is PublishAfterSaveException) {
          // Saved under this URL name; only the publish needs retrying.
          _publicRentalSlugController.text = slug;
          _savedSlug = slug;
        }
        _isSavingPublicSettings = false;
        _publicSettingsError = saveThenPublishErrorText(e,
            saveFailed: 'Failed to save public rental settings');
      });
      unawaited(_readPublishedWebsite());
    }
  }

  /// Opens Website Setup, where the public website is switched and the
  /// add-on bought, then re-reads what can change there: the website
  /// setting, the add-on, and the public URL name, which Website Setup also
  /// edits. A full [_loadPublicRentalSettings] would drop unsaved rental
  /// edits here, and keeping the old URL name would put it back on the next
  /// save here.
  Future<void> _openWebsiteSetup() async {
    await context
        .push('${AppRoute.websiteSetup}?facilityId=${widget.facility.id}');
    if (!mounted) return;
    final facilityFuture = ref
        .read(facilityEditActionsProvider)
        .facility(widget.facility.id)
        .then<FacilityModel?>((f) => f, onError: (_) => null);
    final FacilityPublicSettings settings;
    try {
      // Throws on a failed read, as the first load does. This read returned
      // null then, which kept the old URL name here, and the next save here
      // wrote it back and republished under it.
      settings = await FacilityPublicService.getPublicSettingsOrThrow(
          widget.facility.id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _publicSettingsLoaded = false;
        _publicSettingsError = '${publicSettingsLoadErrorText(e)} Saving '
            'here is off until they load, so it cannot undo changes made in '
            'Website Setup.';
      });
      return;
    }
    final facility = await facilityFuture;
    if (!mounted) return;
    setState(() {
      if (facility != null) {
        _websiteEntitled = facility.hasActiveWebsiteSubscription;
      }
      _websiteEnabled = settings.enabled;
      final storedSlug = settings.publicRentalSlug?.trim();
      // Take a URL name changed in Website Setup, unless the owner has
      // an unsaved one typed here.
      if (storedSlug != null &&
          storedSlug.isNotEmpty &&
          storedSlug != _savedSlug &&
          _publicRentalSlugController.text.trim() == _savedSlug) {
        _publicRentalSlugController.text = storedSlug;
        _savedSlug = storedSlug;
      }
    });
    unawaited(_readPublishedWebsite());
  }

  /// Shown, not switched: the website is switched in Website Setup, and
  /// saving this section leaves it as it is (it used to turn it on). The
  /// Main Rent Link, All Available Units link and Preview go through
  /// /f/{slug}/rent (PublicRentEntryPage), which opens the website's unit
  /// list when the website is live and the rental portal otherwise. Live is
  /// what renderPublicWebsite checks: the published map has the website on
  /// and the facility has the add-on. This read the saved setting instead,
  /// so after a publish that failed it said "on" while /w/ answered
  /// "Website not found".
  Widget _buildWebsiteStatus() {
    const toWebsite = 'The Main Rent Link, All Available Units link and '
        "Preview Public Page open your website's unit list.";
    const toRentalPage = 'The Main Rent Link, All Available Units link and '
        'Preview Public Page open your online rental page. Once your '
        "website is live, they open your website's unit list instead.";
    final published = _publishedWebsiteOn;
    final websiteLive = published == true && _websiteEntitled;
    final String title;
    final String subtitle;
    if (published == null) {
      title = _publishedWebsiteReadFailed
          ? 'Could not check your website'
          : 'Checking your website...';
      subtitle = 'The Main Rent Link, All Available Units link and Preview '
          "Public Page open your website's unit list while it is live, and "
          'your online rental page otherwise.';
    } else if (websiteLive) {
      title = 'Your website is on';
      // The next publish copies the saved setting, off, over the live one.
      subtitle = _websiteEnabled
          ? toWebsite
          : '$toWebsite Website Setup has it switched off, so the next save '
              'here or there takes it down. Turn it on there to keep it.';
    } else if (!_websiteEntitled && (published || _websiteEnabled)) {
      title = 'Your website needs the website add-on';
      subtitle = toRentalPage;
    } else if (_websiteEnabled) {
      title = 'Your website is not published';
      subtitle = 'It is switched on in Website Setup, but the last publish '
          'did not go through. Save there to publish it. $toRentalPage';
    } else {
      title = 'Your website is off';
      subtitle = toRentalPage;
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        websiteLive ? Icons.language : Icons.public_off_outlined,
        color: websiteLive ? AppTheme.success : AppTheme.textSecondary,
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: TextButton(
        onPressed: _openWebsiteSetup,
        child: const Text('Change in Website Setup'),
      ),
    );
  }

  /// Uploads the logo printed on statements and invoices. PNG and JPEG only,
  /// because those are the formats the PDF renderer can embed.
  Future<void> _uploadLogo() async {
    setState(() {
      _isUploadingLogo = true;
      _logoError = null;
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg'],
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
      if (file.bytes!.length > 2 * 1024 * 1024) {
        throw Exception('Logo must be under 2 MB.');
      }
      final ext = (file.extension ?? 'png').toLowerCase();
      final contentType = ext == 'png' ? 'image/png' : 'image/jpeg';
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final ref = FirebaseStorage.instance.ref(
          'facilities/${widget.facility.id}/public-branding/document-logo-$stamp.$ext');
      await ref.putData(file.bytes!, SettableMetadata(contentType: contentType));
      final url = await ref.getDownloadURL();
      if (!mounted) return;
      setState(() {
        _logoUrl = url;
        _isUploadingLogo = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isUploadingLogo = false;
        _logoError =
            'Logo upload failed: ${ErrorMessageHelper.getUserFriendlyMessage(e)}';
      });
    }
  }

  Widget _buildLogoPicker() {
    final hasLogo = _logoUrl != null && _logoUrl!.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Logo',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        const Text(
          'Printed at the top of statements, invoices and receipts. PNG or JPG, under 2 MB. Set its size and position below.',
          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Container(
              width: 120,
              height: 64,
              decoration: BoxDecoration(
                border: Border.all(
                    color: AppTheme.textSecondary.withValues(alpha: 0.3)),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(6),
              alignment: Alignment.center,
              child: hasLogo
                  ? Image.network(
                      _logoUrl!,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.broken_image_outlined),
                    )
                  : const Icon(Icons.image_outlined,
                      color: AppTheme.textSecondary),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: _isUploadingLogo ? null : _uploadLogo,
              icon: _isUploadingLogo
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload),
              label: Text(hasLogo ? 'Replace' : 'Upload logo'),
            ),
            if (hasLogo) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: _isUploadingLogo
                    ? null
                    : () => setState(() => _logoUrl = ''),
                child: const Text('Remove'),
              ),
            ],
          ],
        ),
        if (_logoError != null) ...[
          const SizedBox(height: 6),
          Text(_logoError!, style: const TextStyle(color: AppTheme.error)),
        ],
      ],
    );
  }

  /// Logo size, position and name toggle, with a live preview that follows
  /// the name, address, mailing address, phone and email fields as they are
  /// typed, so the owner sees the header before saving.
  Widget _buildLogoLayoutEditor() {
    final hasLogo = _logoUrl != null && _logoUrl!.isNotEmpty;
    return ListenableBuilder(
      listenable: Listenable.merge([
        _nameController,
        _addressController,
        _mailingAddressController,
        _phoneController,
        _emailController,
      ]),
      builder: (context, _) => DocumentLogoLayoutEditor(
        value: _documentLogo,
        onChanged: (v) => setState(() => _documentLogo = v),
        logo: hasLogo ? NetworkImage(_logoUrl!) : null,
        facilityName: _nameController.text,
        address: _addressController.text,
        mailingAddress: _mailingAddressController.text,
        phone: _phoneController.text,
        email: _emailController.text,
      ),
    );
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
        // Blank clears the default rather than saving 0, so a facility
        // that takes no deposit has no key to prefill from.
        final securityDeposit =
            double.tryParse(_securityDepositController.text.trim());
        billingSettings = {
          'gracePeriodDays': gracePeriod,
          'lateFeeType': _lateFeeType,
          'lateFeeAmount': lateFeeAmount,
          'enableAutoLateFees': _autoLateFees,
          'securityDeposit': securityDeposit == null || securityDeposit <= 0
              ? FieldValue.delete()
              : securityDeposit,
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
        // Empty strings clear these, so an owner can remove them again.
        mailingAddress: _mailingAddressController.text.trim(),
        statementMessage: _statementMessageController.text.trim(),
        logoUrl: _logoUrl == widget.facility.logoUrl ? null : (_logoUrl ?? ''),
        documentLogo: _documentLogo == widget.facility.documentLogo
            ? null
            : _documentLogo,
        phone: _phoneController.text.trim().isEmpty
            ? null
            : _phoneController.text.trim(),
        email: _emailController.text.trim().isEmpty
            ? null
            : _emailController.text.trim(),
        timeZone: _selectedTimeZone,
        billingSettings: billingSettings,
        totalUnits: totalUnits,
        // Written only when changed; turning it off is refused there while
        // two units share a number.
        unitNumbersRepeatAcrossAreas: _unitNumbersRepeat ==
                widget.facility.unitNumbersRepeatAcrossAreas
            ? null
            : _unitNumbersRepeat,
      );

      // No stats step on save. It used to await a client-side orphan heal
      // and recompute here (reads plus a stats write that was always
      // denied); nothing on this form changes unit counts, and the Cloud
      // Function keeps them current on every unit and tenant write.

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
          _errorMessage =
              e is UserFacingException ? e.message : e.toString();
        });
      }
    }
  }

  /// The "Unit numbers repeat across areas" switch. Turning it off checks
  /// first that no two units share a number (the save checks again).
  Future<void> _setUnitNumbersRepeat(bool on) async {
    if (on || !widget.facility.unitNumbersRepeatAcrossAreas) {
      setState(() {
        _unitNumbersRepeat = on;
        _unitNumbersRepeatError = null;
      });
      return;
    }
    setState(() {
      _checkingUnitNumbersRepeat = true;
      _unitNumbersRepeatError = null;
    });
    String? refusal;
    try {
      await UnitService.checkCanStopRepeatingUnitNumbers(widget.facility.id);
    } on RepeatedUnitNumbersException catch (e) {
      refusal = e.message;
    } catch (_) {
      // Could not check now: Update Facility checks again before saving.
    }
    if (!mounted) return;
    setState(() {
      _checkingUnitNumbersRepeat = false;
      _unitNumbersRepeatError = refusal;
      if (refusal == null) _unitNumbersRepeat = false;
    });
  }

  Widget _buildUnitNumbersRepeatSetting() {
    return UnitNumbersRepeatSetting(
      value: _unitNumbersRepeat,
      onChanged: _setUnitNumbersRepeat,
      checking: _checkingUnitNumbersRepeat,
      error: _unitNumbersRepeatError,
      onlineRentalsEnabled: !_isLoadingPublicSettings && _publicRentalsEnabled,
    );
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

                  // Mailing address (optional)
                  TextFormField(
                    controller: _mailingAddressController,
                    decoration: const InputDecoration(
                      labelText: 'Mailing Address (if different)',
                      hintText: 'PO Box 123, City, State 12345',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.mail_outline),
                      alignLabelWithHint: true,
                      helperText:
                          'Where tenants mail payments. Shown on statements and invoices.',
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
                  _sectionTitle('Statements & Invoices'),
                  const SizedBox(height: 16),
                  _buildLogoPicker(),
                  const SizedBox(height: 16),
                  _buildLogoLayoutEditor(),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _statementMessageController,
                    decoration: const InputDecoration(
                      labelText: 'Message on statements',
                      hintText:
                          'Please make payment by the due date to avoid late fees.',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.description_outlined),
                      alignLabelWithHint: true,
                      helperText:
                          'Printed at the bottom of every account statement. Leave blank for the default.',
                    ),
                    maxLines: 3,
                    maxLength: 500,
                  ),
                  const SizedBox(height: 24),

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
                  const SizedBox(height: 16),

                  _buildUnitNumbersRepeatSetting(),
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
                  const SizedBox(height: 8),
                  SwitchListTile(
                    key: const Key('facility-auto-late-fees'),
                    contentPadding: EdgeInsets.zero,
                    value: _autoLateFees,
                    onChanged: (value) =>
                        setState(() => _autoLateFees = value),
                    title: const Text('Charge late fees automatically'),
                    subtitle: Text(_autoLateFees
                        ? 'Each night, tenants who owe a balance and are past '
                            'the grace period get this late fee on their '
                            'ledger, once a month. Only tenants with a '
                            '"paid through" date set are charged.'
                        : 'Off: no late fee is added to any tenant\'s ledger '
                            'automatically. When on, fees only apply to '
                            'tenants with a "paid through" date set.'),
                  ),
                  const SizedBox(height: 16),

                  // Default security deposit. Only a prefill: nothing is
                  // charged from it, online or at move-in.
                  TextFormField(
                    key: const Key('facility-default-security-deposit'),
                    controller: _securityDepositController,
                    decoration: const InputDecoration(
                      labelText: 'Default security deposit (\$)',
                      hintText: '25.00',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.savings_outlined),
                      helperText: 'Prefilled when you record a deposit on a '
                          'tenant. Held for the tenant, off the ledger; '
                          'leave blank if you take none.',
                    ),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    validator: (value) {
                      if (value != null && value.trim().isNotEmpty) {
                        final amount = double.tryParse(value.trim());
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
                  else if (!_publicSettingsLoaded)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: _loadPublicRentalSettings,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Load public rental settings again'),
                      ),
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
                    _buildWebsiteStatus(),
                    const SizedBox(height: 8),
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
