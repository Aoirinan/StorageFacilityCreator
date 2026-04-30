import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/services/facility_map_v2_service.dart';
import 'package:sfcapp/services/public_rental_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:url_launcher/url_launcher.dart';

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
  static const double _contentMaxWidth = 1120;

  /// Hash routes (`/#/f/...?embed=1`) put query params in [Uri.fragment], not
  /// [Uri.queryParameters]. Parse both so embedded mode actually activates.
  Map<String, String> _locationQueryParams() {
    final merged = Map<String, String>.from(Uri.base.queryParameters);
    final frag = Uri.base.fragment;
    if (frag.isNotEmpty) {
      final q = frag.indexOf('?');
      if (q != -1 && q < frag.length - 1) {
        merged.addAll(Uri.splitQueryString(frag.substring(q + 1)));
      }
    }
    return merged;
  }

  bool get _isEmbeddedMode => _locationQueryParams()['embed'] == '1';

  bool _isLoading = true;
  String? _error;
  String? _facilitySlug;
  String? _facilityId;
  String _facilityName = 'Rent Online';
  String? _facilityDescription;
  String? _facilityPhone;
  String? _facilityLogoUrl;
  String? _customDomain;
  Color _heroGradientStart = const Color(0xFF0C1E4D);
  Color _heroGradientEnd = const Color(0xFF1E5BD4);
  Color _heroTextColor = Colors.white;
  Color _ctaButtonColor = const Color(0xFF103A86);
  String? _heroImageUrl;
  String? _stepChooseIconUrl;
  String? _stepDetailsIconUrl;
  String? _stepReserveIconUrl;
  String? _promiseSecurityIconUrl;
  String? _promiseServiceIconUrl;
  String? _promiseConvenienceIconUrl;
  String _promiseSecurityText = 'Secure and well-monitored property';
  String _promiseServiceText = 'Friendly support when you need help';
  String _promiseConvenienceText = 'Fast online reservation and move-in flow';

  bool _publicRentalsEnabled = false;
  bool _publicPricingEnabled = true;
  bool _publicUnitNumbersEnabled = true;
  bool _allowAutoAssign = true;
  bool _allowUnitSelection = true;
  bool _showAvailabilityCount = true;
  bool _hideUnavailableTypes = true;
  Set<String> _enabledPublicUnitTypes = <String>{};
  Map<String, String> _unitTypeImageUrls = <String, String>{};

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
      final locQ = _locationQueryParams();
      _preferredUnitId = locQ['unitId'];
      _preferredUnitType = locQ['unitType'];

      final enabledTypes =
          (settings['enabledPublicUnitTypes'] as List<dynamic>? ??
                  const <dynamic>[])
              .map((e) => e.toString())
              .where((e) => e.trim().isNotEmpty)
              .toSet();
      final unitTypeImageUrls =
          (settings['unitTypeImageUrls'] as Map<String, dynamic>? ??
                  const <String, dynamic>{})
              .map((key, value) => MapEntry(key.toString(), value.toString()));
      final customStyles = _coerceStyleMap(settings['customStyles']);
      final websiteConfig = _coerceStyleMap(settings['websiteConfig']);
      final featuredImages =
          (settings['featuredImages'] as List<dynamic>? ?? const <dynamic>[])
              .map((e) => e.toString())
              .where((e) => e.trim().isNotEmpty)
              .toList();

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
        _customDomain = settings['customDomain']?.toString();
        _heroGradientStart = _parseColor(
          customStyles['heroGradientStart']?.toString(),
          const Color(0xFF0C1E4D),
        );
        _heroGradientEnd = _parseColor(
          customStyles['heroGradientEnd']?.toString(),
          const Color(0xFF1E5BD4),
        );
        _heroTextColor = _parseColor(
          customStyles['heroTextColor']?.toString(),
          Colors.white,
        );
        _ctaButtonColor = _parseColor(
          customStyles['ctaButtonColor']?.toString(),
          const Color(0xFF103A86),
        );
        _heroImageUrl = featuredImages.isNotEmpty ? featuredImages.first : null;
        _stepChooseIconUrl = websiteConfig['stepChooseIconUrl']?.toString();
        _stepDetailsIconUrl = websiteConfig['stepDetailsIconUrl']?.toString();
        _stepReserveIconUrl = websiteConfig['stepReserveIconUrl']?.toString();
        _promiseSecurityIconUrl =
            websiteConfig['promiseSecurityIconUrl']?.toString();
        _promiseServiceIconUrl =
            websiteConfig['promiseServiceIconUrl']?.toString();
        _promiseConvenienceIconUrl =
            websiteConfig['promiseConvenienceIconUrl']?.toString();
        _promiseSecurityText =
            _asNonEmptyOrDefault(websiteConfig['promiseSecurity']?.toString(),
                'Secure and well-monitored property');
        _promiseServiceText =
            _asNonEmptyOrDefault(websiteConfig['promiseService']?.toString(),
                'Friendly support when you need help');
        _promiseConvenienceText = _asNonEmptyOrDefault(
          websiteConfig['promiseConvenience']?.toString(),
          'Fast online reservation and move-in flow',
        );
        _publicRentalsEnabled = settings['publicRentalsEnabled'] == true;
        _publicPricingEnabled = settings['showPublicPricing'] != false;
        _publicUnitNumbersEnabled =
            settings['publicUnitNumbersEnabled'] != false;
        _allowAutoAssign = settings['allowAutoAssign'] != false;
        _allowUnitSelection = settings['allowUnitSelection'] != false;
        _showAvailabilityCount = settings['showAvailabilityCount'] != false;
        _hideUnavailableTypes = settings['hideUnavailableTypes'] != false;
        _enabledPublicUnitTypes = enabledTypes;
        _unitTypeImageUrls = unitTypeImageUrls;
        _units = publicUnits;
        _selectedCategorySlug = widget.initialCategorySlug;
        _isLoading = false;
      });

      _maybeAutoStartRental();
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

  Future<void> _dialFacilityPhone() async {
    final raw = _facilityPhone?.trim();
    if (raw == null || raw.isEmpty) return;
    final normalized = raw.replaceAll(RegExp(r'[^\d+]'), '');
    if (normalized.isEmpty) return;
    final uri = Uri(scheme: 'tel', path: normalized);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      }
    } catch (_) {
      /* ignore launch failures on unsupported platforms */
    }
  }

  String _originBase() {
    final origin = Uri.base.origin;
    if (origin.isNotEmpty) return origin;
    return 'https://app.storagefacilitycreator.com';
  }

  String _publicWebsiteBaseUrl() {
    final slug = _facilitySlug?.trim();
    if (slug == null || slug.isEmpty) return _originBase();
    return '${_originBase()}/w/$slug';
  }

  String _publicUnitsUrl() {
    final slug = _facilitySlug?.trim();
    if (slug == null || slug.isEmpty) return _originBase();
    return '${_originBase()}/w/$slug#units';
  }

  String _publicMapUrl() {
    final slug = _facilitySlug?.trim();
    if (slug == null || slug.isEmpty) return _originBase();
    return '${_originBase()}/public/$slug/map';
  }

  Future<void> _openPublicUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      await launchUrl(
        uri,
        mode: LaunchMode.platformDefault,
        webOnlyWindowName: '_self',
      );
    } catch (_) {
      /* no-op if navigation fails */
    }
  }

  /// Re-read `publicFacilityMaps` so the list matches what Cloud Functions enforce.
  Future<void> _reloadInventoryFromPublishedSnapshot() async {
    final slug = _facilitySlug;
    if (slug == null || slug.trim().isEmpty) return;
    try {
      final snapshot =
          await FacilityMapV2Service.getPublicSnapshotBySlug(slug.trim());
      if (!mounted || snapshot == null) return;
      final publicUnits = snapshot.units
          .map((raw) => _PublicUnitView.fromMap(raw))
          .where((u) => u.unitId.isNotEmpty)
          .toList();
      setState(() {
        _units = publicUnits;
      });
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ [PublicRentalPortal] Inventory refresh failed: $e');
      }
    }
  }

  bool _autoStartFired = false;

  bool get _isAutoSubmitMode {
    final params = _locationQueryParams();
    return params['autoSubmit'] == '1' &&
        (params['email']?.trim().isNotEmpty == true);
  }

  /// When arriving from the marketing page with autoSubmit=1 and form data
  /// in the URL, skip all UI and submit the reservation directly.
  Future<void> _maybeAutoStartRental() async {
    if (_autoStartFired) return;
    if (!_isEmbeddedMode) return;
    if (!_publicRentalsEnabled) return;

    final params = _locationQueryParams();
    final hasAutoSubmit = params['autoSubmit'] == '1' &&
        (params['email']?.trim().isNotEmpty == true);
    if (!hasAutoSubmit) return;

    _autoStartFired = true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;

    _PublicUnitView? unit;
    final targetId = _preferredUnitId;

    if (targetId != null && targetId.trim().isNotEmpty) {
      unit = _units.cast<_PublicUnitView?>().firstWhere(
            (u) => u!.unitId == targetId && _unitStillRentableOnline(u),
            orElse: () => null,
          );
    }

    if (unit == null) {
      final groups = _groups;
      if (groups.isEmpty) {
        _showAutoSubmitError('No units are currently available.');
        return;
      }
      final available = groups.first.availableUnits;
      if (available.isEmpty) {
        _showAutoSubmitError('No units are currently available.');
        return;
      }
      unit = available.first;
    }

    _handleDirectSubmit(unit, params);
  }

  void _showAutoSubmitError(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
    });
  }

  /// Submit the reservation directly using form data from URL params.
  Future<void> _handleDirectSubmit(
      _PublicUnitView unit, Map<String, String> params) async {
    if (_facilityId == null) return;

    final email = params['email']?.trim() ?? '';
    final name = params['name']?.trim();
    final phone = params['phone']?.trim();
    final moveInDateStr = params['moveInDate']?.trim();

    if (email.isEmpty || !email.contains('@')) {
      _showAutoSubmitError('Invalid email address provided.');
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      await _reloadInventoryFromPublishedSnapshot();
      if (!mounted) return;

      if (!_unitStillRentableOnline(unit)) {
        _showAutoSubmitError(
            'That unit is no longer available. Please go back and choose another.');
        return;
      }

      final reservation = await PublicRentalService.createReservation(
        facilityId: _facilityId!,
        unitId: unit.unitId,
        unitNumber: _publicUnitNumbersEnabled ? unit.unitLabel : null,
        email: email,
        phone: (phone != null && phone.isNotEmpty) ? phone : null,
        name: (name != null && name.isNotEmpty) ? name : null,
        moveInDate: (moveInDateStr != null && moveInDateStr.isNotEmpty)
            ? DateTime.tryParse(moveInDateStr)
            : null,
        expirationDuration: const Duration(minutes: 10),
        metadata: <String, dynamic>{
          'source': 'publicWebsite',
          'facilitySlug': _facilitySlug,
          'autoAssigned': _preferredUnitId == null,
          'directFromWebsite': true,
        },
      );

      if (!mounted) return;
      unawaited(
          context.push('/public-move-in?token=${reservation.moveInToken}'));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Unable to complete reservation. Please try again.';
        _isLoading = false;
      });
    }
  }

  bool _unitStillRentableOnline(_PublicUnitView u) =>
      (u.status == 'available' || u.status == 'reserved') && u.isRentable;

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

  Color _parseColor(String? raw, Color fallback) {
    if (raw == null || raw.trim().isEmpty) return fallback;
    var cleaned = raw.trim().replaceAll('#', '');
    if (cleaned.length == 3 && RegExp(r'^[0-9a-fA-F]{3}$').hasMatch(cleaned)) {
      cleaned =
          '${cleaned[0]}${cleaned[0]}${cleaned[1]}${cleaned[1]}${cleaned[2]}${cleaned[2]}';
    }
    if (cleaned.length == 6 && RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(cleaned)) {
      return Color(int.parse('FF$cleaned', radix: 16));
    }
    return fallback;
  }

  static Map<String, dynamic> _coerceStyleMap(dynamic raw) {
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v));
    }
    return const <String, dynamic>{};
  }

  String _asNonEmptyOrDefault(String? value, String fallback) {
    final cleaned = value?.trim();
    if (cleaned == null || cleaned.isEmpty) return fallback;
    return cleaned;
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: AppTheme.backgroundLight,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: AppTheme.backgroundLight,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error!, textAlign: TextAlign.center),
          ),
        ),
      );
    }

    if (_isAutoSubmitMode) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 18),
              Text(
                'Completing your reservation...',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF64748B),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final groups = _groups;
    final sheetBg = _isEmbeddedMode ? Colors.white : const Color(0xFFF7FAFC);
    return Scaffold(
      backgroundColor: sheetBg,
      body: RefreshIndicator(
        onRefresh: _reloadInventoryFromPublishedSnapshot,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          children: [
            if (!_isEmbeddedMode) _buildFacilityHeader(),
            if (!_isEmbeddedMode)
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(22, 12, 22, 0),
                    child: _buildPublicNavBar(),
                  ),
                ),
              ),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
                child: Container(
                  color: sheetBg,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      22,
                      _isEmbeddedMode ? 12 : 18,
                      22,
                      _isEmbeddedMode ? 14 : 28,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!_isEmbeddedMode) ...[
                          _buildJourneyStrip(),
                          const SizedBox(height: 14),
                        ],
                        if (_isEmbeddedMode) ...[
                          _buildEmbedSectionHeader(),
                          if (_categorySlugs.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            _buildCategoryDropdown(),
                          ],
                        ] else ...[
                          _buildSectionHeader(
                            title: 'Available Units',
                            subtitle: _categorySlugs.isEmpty
                                ? 'Pick a unit type and reserve online in minutes.'
                                : 'Filter by unit type to find the right fit quickly.',
                          ),
                          if (_categorySlugs.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            _buildCategoryTabs(),
                          ],
                        ],
                        const SizedBox(height: 14),
                        if (groups.isEmpty)
                          _buildEmptyState()
                        else
                          ...groups.map(
                            (g) => _isEmbeddedMode
                                ? _buildEmbedGroupCard(g)
                                : _buildGroupCard(g),
                          ),
                        if (!_isEmbeddedMode) ...[
                          const SizedBox(height: 12),
                          _buildInfoRail(),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmbedSectionHeader() {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Available units',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: Color(0xFF0F172A),
            letterSpacing: -0.3,
          ),
        ),
        SizedBox(height: 4),
        Text(
          'Choose a unit type, then continue.',
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 14,
            height: 1.35,
          ),
        ),
      ],
    );
  }

  Widget _buildCategoryDropdown() {
    final slugs = _categorySlugs;
    return InputDecorator(
      decoration: InputDecoration(
        labelText: 'Unit type',
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _ctaButtonColor, width: 2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          isExpanded: true,
          value: _selectedCategorySlug,
          borderRadius: BorderRadius.circular(12),
          hint: const Text('All types'),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('All types'),
            ),
            ...slugs.map(
              (s) => DropdownMenuItem<String?>(
                value: s,
                child: Text(_displayCategory(s)),
              ),
            ),
          ],
          onChanged: (v) => setState(() => _selectedCategorySlug = v),
        ),
      ),
    );
  }

  Widget _buildEmbedGroupCard(_UnitTypeGroup group) {
    final availableCount = group.availableUnits.length;
    final unavailable = availableCount == 0;
    final monthlyRate = group.lowestRate;
    final canRent = _publicRentalsEnabled &&
        !unavailable &&
        (_allowAutoAssign || _allowUnitSelection);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x080F172A),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  group.title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0F172A),
                    height: 1.25,
                  ),
                ),
              ),
              if (_showAvailabilityCount)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: unavailable
                          ? const Color(0xFFFFE9E9)
                          : const Color(0xFFE7F7EE),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      unavailable
                          ? 'Unavailable'
                          : availableCount == 1
                              ? '1 left'
                              : '$availableCount left',
                      style: TextStyle(
                        color: unavailable
                            ? AppTheme.error
                            : AppTheme.success,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (_publicPricingEnabled && monthlyRate != null) ...[
            const SizedBox(height: 6),
            Text(
              '\$${monthlyRate.toStringAsFixed(0)}/month',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: _ctaButtonColor,
                fontSize: 18,
              ),
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _ctaButtonColor,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(44),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: canRent ? () => _handleRentNow(group) : null,
              child: Text(unavailable ? 'Unavailable' : 'Reserve this unit'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFacilityHeader() {
    final totalAvailable = _groups.fold<int>(
      0,
      (sum, group) => sum + group.availableUnits.length,
    );
    return Container(
      width: double.infinity,
      padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            _heroGradientStart,
            Color.lerp(_heroGradientStart, _heroGradientEnd, 0.55)!,
            _heroGradientEnd,
          ],
          stops: <double>[0, 0.45, 1],
        ),
      ),
      child: Stack(
        children: [
          if (_heroImageUrl != null && _heroImageUrl!.trim().isNotEmpty)
            Positioned.fill(
              child: Image.network(
                _heroImageUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          if (_heroImageUrl != null && _heroImageUrl!.trim().isNotEmpty)
            Positioned.fill(
              child: Container(
                color: _heroGradientStart.withValues(alpha: 0.58),
              ),
            ),
          Positioned(
            right: -40,
            top: -24,
            child: IgnorePointer(
              child: Container(
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.06),
                ),
              ),
            ),
          ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 6, 22, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
              if (_facilityLogoUrl != null &&
                  _facilityLogoUrl!.trim().isNotEmpty) ...[
                Material(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Image.network(
                      _facilityLogoUrl!,
                      height: 44,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
                    Text(
                      _facilityName,
                      style: TextStyle(
                        fontSize: 42,
                        height: 1.08,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1.05,
                        color: _heroTextColor,
                      ),
                    ),
              const SizedBox(height: 8),
              Text(
                'Rent storage units in minutes',
                style: TextStyle(
                  fontSize: 18,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: _heroTextColor.withValues(alpha: 0.88),
                  letterSpacing: 0.15,
                ),
              ),
              if (_facilityPhone != null && _facilityPhone!.trim().isNotEmpty) ...[
                const SizedBox(height: 14),
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _dialFacilityPhone,
                    borderRadius: BorderRadius.circular(999),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.phone_in_talk_rounded,
                            size: 18,
                            color: _heroTextColor.withValues(alpha: 0.95),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _facilityPhone!,
                            style: TextStyle(
                              color: _heroTextColor.withValues(alpha: 0.95),
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              decoration: TextDecoration.underline,
                              decorationColor:
                                  _heroTextColor.withValues(alpha: 0.35),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              if (_facilityDescription != null &&
                  _facilityDescription!.trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  _facilityDescription!,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.45,
                    color: _heroTextColor.withValues(alpha: 0.82),
                  ),
                ),
              ],
              if (_customDomain != null && _customDomain!.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _customDomain!,
                  style: TextStyle(
                    color: _heroTextColor.withValues(alpha: 0.92),
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _MetaPill(
                    icon: Icons.check_circle_outline,
                    label: totalAvailable == 1
                        ? '1 unit available'
                        : '$totalAvailable units available',
                    textColor: _heroTextColor,
                  ),
                  if (_publicPricingEnabled)
                    _MetaPill(
                      icon: Icons.attach_money_rounded,
                      label: 'Transparent monthly pricing',
                      textColor: _heroTextColor,
                    ),
                  _MetaPill(
                    icon: Icons.bolt_rounded,
                    label: 'Online reservation flow',
                    textColor: _heroTextColor,
                  ),
                ],
              ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildJourneyStrip() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F5)),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _StepChip(
            index: 1,
            label: 'Choose unit',
            highlighted: true,
            accentColor: _ctaButtonColor,
            textColor: const Color(0xFF0F172A),
            iconUrl: _stepChooseIconUrl,
          ),
          _StepChip(
            index: 2,
            label: 'Enter details',
            highlighted: false,
            accentColor: _ctaButtonColor,
            textColor: const Color(0xFF0F172A),
            iconUrl: _stepDetailsIconUrl,
          ),
          _StepChip(
            index: 3,
            label: 'Reserve online',
            highlighted: false,
            accentColor: _ctaButtonColor,
            textColor: const Color(0xFF0F172A),
            iconUrl: _stepReserveIconUrl,
          ),
        ],
      ),
    );
  }

  Widget _buildPublicNavBar() {
    final websiteBase = _publicWebsiteBaseUrl();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F5)),
      ),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        alignment: WrapAlignment.center,
        children: [
          _PublicNavButton(
            label: 'Home',
            onTap: () => _openPublicUrl(websiteBase),
          ),
          _PublicNavButton(
            label: 'About',
            onTap: () => _openPublicUrl('$websiteBase#about'),
          ),
          _PublicNavButton(
            label: 'Units',
            onTap: () => _openPublicUrl(_publicUnitsUrl()),
          ),
          _PublicNavButton(
            label: 'Map',
            onTap: () => _openPublicUrl(_publicMapUrl()),
          ),
          _PublicNavButton(
            label: 'Contact',
            onTap: () => _openPublicUrl('$websiteBase#contact'),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryTabs() {
    final slugs = _categorySlugs;
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _CategoryFilterChip(
            label: 'All',
            selected: _selectedCategorySlug == null,
            selectedColor: _ctaButtonColor,
            onTap: () => setState(() => _selectedCategorySlug = null),
          ),
          ...slugs.map(
            (slug) => _CategoryFilterChip(
              label: _displayCategory(slug),
              selected: _selectedCategorySlug == slug,
              selectedColor: _ctaButtonColor,
              onTap: () => setState(() => _selectedCategorySlug = slug),
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

    final imageUrl = _unitTypeImageUrls[_normalizeUnitTypeKey(group.unitType)];

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFDCE5F3)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x120F1C3D),
            blurRadius: 12,
            offset: Offset(0, 4),
          )
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (imageUrl != null && imageUrl.trim().isNotEmpty) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  height: 180,
                  width: double.infinity,
                  child: Image.network(
                    imageUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              ),
              const SizedBox(height: 14),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Text(
                        group.title,
                        style: const TextStyle(
                          fontSize: 34,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF111827),
                          letterSpacing: -0.8,
                        ),
                      ),
                      if (_showAvailabilityCount)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: availableCount == 0
                                ? const Color(0xFFFFE9E9)
                                : const Color(0xFFE7F7EE),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            availableCount == 0
                                ? 'Unavailable'
                                : availableCount == 1
                                    ? '1 left'
                                    : '$availableCount left',
                            style: TextStyle(
                              color: availableCount == 0
                                  ? AppTheme.error
                                  : AppTheme.success,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (_publicPricingEnabled && monthlyRate != null)
                  Text(
                    '\$${monthlyRate.toStringAsFixed(0)}/month',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF103A86),
                      fontSize: 38,
                      letterSpacing: -1,
                    ),
                  ),
              ],
            ),
            if (group.description != null &&
                group.description!.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                group.description!,
                style: const TextStyle(color: AppTheme.textSecondary),
              ),
            ],
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _ctaButtonColor,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: canRent ? () => _handleRentNow(group) : null,
                child: Text(unavailable ? 'Unavailable' : 'Reserve This Unit'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWhyRentSection() {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Why Rent Here?',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          _WhyRentItem(
            text: _promiseSecurityText,
            iconUrl: _promiseSecurityIconUrl,
            fallbackIcon: Icons.shield_outlined,
            accentColor: _ctaButtonColor,
          ),
          const SizedBox(height: 8),
          _WhyRentItem(
            text: _promiseServiceText,
            iconUrl: _promiseServiceIconUrl,
            fallbackIcon: Icons.support_agent_outlined,
            accentColor: _ctaButtonColor,
          ),
          const SizedBox(height: 8),
          _WhyRentItem(
            text: _promiseConvenienceText,
            iconUrl: _promiseConvenienceIconUrl,
            fallbackIcon: Icons.flash_on_outlined,
            accentColor: _ctaButtonColor,
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader({required String title, required String subtitle}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w800,
            color: Color(0xFF0F172A),
            letterSpacing: -0.8,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: const TextStyle(
            color: AppTheme.textSecondary,
            height: 1.35,
            fontSize: 16,
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRail() {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 900) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _buildWhyRentSection()),
              const SizedBox(width: 12),
              Expanded(child: _buildFaqSection()),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildWhyRentSection(),
            const SizedBox(height: 12),
            _buildFaqSection(),
          ],
        );
      },
    );
  }

  String _normalizeUnitTypeKey(String raw) {
    return raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }

  Widget _buildFaqSection() {
    const faqs = <Map<String, String>>[
      {
        'q': 'How do I rent a unit online?',
        'a': 'Choose a unit, click Rent Now, and complete the short reservation form.'
      },
      {
        'q': 'Can I choose a specific unit?',
        'a': 'If unit selection is enabled by this facility, you can choose from available units.'
      },
      {
        'q': 'How quickly will I hear back?',
        'a': 'Most facilities follow up quickly after reservation to finalize move-in details.'
      },
    ];
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Frequently Asked Questions',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          ...faqs.map((item) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item['q']!,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item['a']!,
                      style: const TextStyle(color: AppTheme.textSecondary),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final hasPhone =
        _facilityPhone != null && _facilityPhone!.trim().isNotEmpty;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFFE2E8F0)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x0F0F172A),
                  blurRadius: 24,
                  offset: Offset(0, 12),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 36, 28, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: const Icon(
                      Icons.inventory_2_outlined,
                      size: 40,
                      color: Color(0xFF64748B),
                    ),
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    'Nothing available online right now',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    hasPhone
                        ? 'Units can open up throughout the day. Call the facility — staff can often help you find the right space.'
                        : 'Please check back soon — availability updates as units turn over.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.5,
                      color: AppTheme.textSecondary.withValues(alpha: 0.95),
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (hasPhone)
                    FilledButton.tonalIcon(
                      onPressed: _dialFacilityPhone,
                      icon: const Icon(Icons.call_rounded, size: 20),
                      label: Text('Call $_facilityPhone'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        foregroundColor: const Color(0xFF0F172A),
                        backgroundColor: const Color(0xFFE8EEF7),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    )
                  else
                    Text(
                      'Check back soon',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textTertiary,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleRentNow(_UnitTypeGroup group) async {
    if (group.availableUnits.isEmpty || _facilityId == null) return;

    await _reloadInventoryFromPublishedSnapshot();
    if (!mounted) return;

    final refreshed = _groups.where((g) => g.key == group.key).toList();
    if (refreshed.isEmpty || refreshed.first.availableUnits.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Availability just changed for this size. Pull down to refresh, then try again.',
            ),
          ),
        );
      }
      return;
    }
    final currentGroup = refreshed.first;

    _PublicUnitView? selectedUnit;
    if (_allowAutoAssign && !_allowUnitSelection) {
      selectedUnit = currentGroup.availableUnits.first;
    } else if (!_allowAutoAssign && _allowUnitSelection) {
      selectedUnit = await _showUnitPicker(currentGroup.availableUnits);
      if (selectedUnit == null) return;
    } else {
      final choice = await _showAssignChoice();
      if (choice == null) return;
      if (choice == _AssignChoice.autoAssign) {
        selectedUnit = currentGroup.availableUnits.first;
      } else {
        selectedUnit = await _showUnitPicker(currentGroup.availableUnits);
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

    await _reloadInventoryFromPublishedSnapshot();
    if (!mounted) return;
    if (!_unitStillRentableOnline(selected)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'That unit is no longer available. Pull down to refresh the list and choose another unit.',
            ),
            backgroundColor: AppTheme.error,
          ),
        );
      }
      return;
    }

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

class _StepChip extends StatelessWidget {
  final int index;
  final String label;
  final bool highlighted;
  final Color accentColor;
  final Color textColor;
  final String? iconUrl;

  const _StepChip({
    required this.index,
    required this.label,
    this.highlighted = false,
    required this.accentColor,
    required this.textColor,
    this.iconUrl,
  });

  @override
  Widget build(BuildContext context) {
    final labelColor =
        highlighted ? const Color(0xFF0F172A) : textColor.withValues(alpha: 0.94);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: highlighted ? Colors.white : Colors.white.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: highlighted
              ? Colors.white.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.22),
          width: 1,
        ),
        boxShadow: highlighted
            ? const [
                BoxShadow(
                  color: Color(0x330F172A),
                  blurRadius: 16,
                  offset: Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (iconUrl != null && iconUrl!.trim().isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: Container(
                width: 22,
                height: 22,
                color: Colors.white.withValues(alpha: 0.92),
                child: Image.network(
                  iconUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      _buildIndexBubble(highlighted, accentColor, index),
                ),
              ),
            )
          else
            _buildIndexBubble(highlighted, accentColor, index),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: labelColor,
              fontWeight: FontWeight.w700,
              fontSize: 13,
              letterSpacing: 0.1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIndexBubble(bool highlighted, Color accentColor, int index) {
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: highlighted ? accentColor : Colors.white.withValues(alpha: 0.92),
        shape: BoxShape.circle,
      ),
      child: Text(
        '$index',
        style: TextStyle(
          color: highlighted ? Colors.white : accentColor,
          fontWeight: FontWeight.w800,
          fontSize: 11,
          height: 1,
        ),
      ),
    );
  }
}

class _MetaPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color textColor;

  const _MetaPill({
    required this.icon,
    required this.label,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: textColor.withValues(alpha: 0.95)),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: textColor.withValues(alpha: 0.96),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _WhyRentItem extends StatelessWidget {
  final String text;
  final String? iconUrl;
  final IconData fallbackIcon;
  final Color accentColor;

  const _WhyRentItem({
    required this.text,
    required this.iconUrl,
    required this.fallbackIcon,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: accentColor.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(999),
          ),
          child: (iconUrl != null && iconUrl!.trim().isNotEmpty)
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: Image.network(
                    iconUrl!,
                    width: 22,
                    height: 22,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Icon(
                      fallbackIcon,
                      size: 14,
                      color: accentColor,
                    ),
                  ),
                )
              : Icon(
                  fallbackIcon,
                  size: 14,
                  color: accentColor,
                ),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    );
  }
}

class _PublicNavButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _PublicNavButton({
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        minimumSize: const Size(0, 36),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          color: Color(0xFF0F172A),
        ),
      ),
    );
  }
}

class _CategoryFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color selectedColor;
  final VoidCallback onTap;

  const _CategoryFilterChip({
    required this.label,
    required this.selected,
    required this.selectedColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? selectedColor : const Color(0xFFEEF2F6),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? selectedColor : const Color(0xFFDCE3ED),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                const Icon(Icons.check_rounded, size: 18, color: Colors.white),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.15,
                  color: selected ? Colors.white : selectedColor,
                ),
              ),
            ],
          ),
        ),
      ),
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
