import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/facility_model.dart';
import '../providers/facility_provider.dart';
import '../router/app_route.dart';
import '../services/facility_map_v2_service.dart';
import '../services/facility_public_service.dart';
import '../services/facility_service.dart';
import '../screens/cancellation/cancellation_retention_wizard.dart';
import '../services/stripe_service.dart';
import '../theme/app_theme.dart';
import '../utils/renter_account_message.dart';

class FacilityWebsiteSetupScreen extends ConsumerStatefulWidget {
  final String facilityId;

  const FacilityWebsiteSetupScreen({
    super.key,
    required this.facilityId,
  });

  @override
  ConsumerState<FacilityWebsiteSetupScreen> createState() =>
      _FacilityWebsiteSetupScreenState();
}

class _FacilityWebsiteSetupScreenState
    extends ConsumerState<FacilityWebsiteSetupScreen> {
  static const List<String> _dayOrder = <String>[
    'sunday',
    'monday',
    'tuesday',
    'wednesday',
    'thursday',
    'friday',
    'saturday',
  ];
  static const List<String> _amenityIconOptions = <String>[
    'clock',
    'truck',
    'shield',
    'key',
    'camera',
    'wifi',
    'zap',
    'snowflake',
    'door-open',
    'map-pin',
    'package',
    'lock',
    'car',
    'building',
  ];

  bool _isLoading = true;
  bool _isSaving = false;
  bool _subscriptionRequired = false;
  bool _isStartingCheckout = false;
  String? _error;

  FacilityModel? _facility;
  List<FacilityModel> _userFacilities = const <FacilityModel>[];

  final TextEditingController _slugController = TextEditingController();
  final TextEditingController _customDomainController = TextEditingController();
  final TextEditingController _pageTitleController = TextEditingController();
  final TextEditingController _pageDescriptionController =
      TextEditingController();
  final TextEditingController _heroHeadlineController = TextEditingController();
  final TextEditingController _heroSubheadlineController =
      TextEditingController();
  final TextEditingController _marketingContentController =
      TextEditingController();
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _officeHoursController = TextEditingController();
  final TextEditingController _amenitiesController = TextEditingController();
  final TextEditingController _testimonialsController = TextEditingController();
  final TextEditingController _paymentUrlController = TextEditingController();
  final TextEditingController _primaryCtaController = TextEditingController();
  final TextEditingController _secondaryCtaController = TextEditingController();
  final TextEditingController _taglineController = TextEditingController();
  final TextEditingController _heroImageUrlController = TextEditingController();
  final TextEditingController _contactEmailController = TextEditingController();
  final TextEditingController _mapEmbedUrlController = TextEditingController();
  final TextEditingController _promoTitleController = TextEditingController();
  final TextEditingController _promoBodyController = TextEditingController();
  final TextEditingController _promoCtaLabelController =
      TextEditingController();
  final TextEditingController _promoCtaUrlController = TextEditingController();
  final TextEditingController _promiseSecurityController =
      TextEditingController();
  final TextEditingController _promiseServiceController =
      TextEditingController();
  final TextEditingController _promiseConvenienceController =
      TextEditingController();
  final TextEditingController _reviewUrlController = TextEditingController();
  final TextEditingController _stepChooseIconUrlController =
      TextEditingController();
  final TextEditingController _stepDetailsIconUrlController =
      TextEditingController();
  final TextEditingController _stepReserveIconUrlController =
      TextEditingController();
  final TextEditingController _promiseSecurityIconUrlController =
      TextEditingController();
  final TextEditingController _promiseServiceIconUrlController =
      TextEditingController();
  final TextEditingController _promiseConvenienceIconUrlController =
      TextEditingController();
  final TextEditingController _heroGradientStartController =
      TextEditingController();
  final TextEditingController _heroGradientEndController =
      TextEditingController();
  final TextEditingController _heroTextColorController =
      TextEditingController();
  final TextEditingController _ctaButtonColorController =
      TextEditingController();
  final TextEditingController _logoImageUrlController = TextEditingController();
  final TextEditingController _phoneNumberController = TextEditingController();
  final TextEditingController _aboutSectionTitleController =
      TextEditingController();
  final TextEditingController _aboutSectionBodyController =
      TextEditingController();
  final TextEditingController _aboutSectionImageUrlController =
      TextEditingController();
  final TextEditingController _partnershipTitleController =
      TextEditingController();
  final TextEditingController _partnershipBodyController =
      TextEditingController();
  final TextEditingController _partnershipImageUrlController =
      TextEditingController();
  final TextEditingController _partnershipCtaLabelController =
      TextEditingController();
  final TextEditingController _partnershipCtaUrlController =
      TextEditingController();
  final TextEditingController _footerTaglineController =
      TextEditingController();
  final TextEditingController _facebookUrlController = TextEditingController();
  final TextEditingController _instagramUrlController = TextEditingController();
  final TextEditingController _googleUrlController = TextEditingController();
  final TextEditingController _footerLegalTextController =
      TextEditingController();
  final TextEditingController _metaKeywordsController = TextEditingController();
  final TextEditingController _ogImageUrlController = TextEditingController();
  final TextEditingController _canonicalUrlController = TextEditingController();

  bool _websiteEnabled = false;
  bool _showPaymentLoginButtonInHeader = true;
  bool _useStructuredOfficeHours = false;
  String? _uploadingFieldKey;
  Map<String, _OfficeDayHours> _officeHoursStructured =
      <String, _OfficeDayHours>{};
  List<Map<String, dynamic>> _unitCategories = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _amenitiesStructured = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _testimonialsStructured = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _faqs = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant FacilityWebsiteSetupScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.facilityId != widget.facilityId) {
      _load();
    }
  }

  @override
  void dispose() {
    _slugController.dispose();
    _customDomainController.dispose();
    _pageTitleController.dispose();
    _pageDescriptionController.dispose();
    _heroHeadlineController.dispose();
    _heroSubheadlineController.dispose();
    _marketingContentController.dispose();
    _addressController.dispose();
    _officeHoursController.dispose();
    _amenitiesController.dispose();
    _testimonialsController.dispose();
    _paymentUrlController.dispose();
    _primaryCtaController.dispose();
    _secondaryCtaController.dispose();
    _taglineController.dispose();
    _heroImageUrlController.dispose();
    _contactEmailController.dispose();
    _mapEmbedUrlController.dispose();
    _promoTitleController.dispose();
    _promoBodyController.dispose();
    _promoCtaLabelController.dispose();
    _promoCtaUrlController.dispose();
    _promiseSecurityController.dispose();
    _promiseServiceController.dispose();
    _promiseConvenienceController.dispose();
    _reviewUrlController.dispose();
    _stepChooseIconUrlController.dispose();
    _stepDetailsIconUrlController.dispose();
    _stepReserveIconUrlController.dispose();
    _promiseSecurityIconUrlController.dispose();
    _promiseServiceIconUrlController.dispose();
    _promiseConvenienceIconUrlController.dispose();
    _heroGradientStartController.dispose();
    _heroGradientEndController.dispose();
    _heroTextColorController.dispose();
    _ctaButtonColorController.dispose();
    _logoImageUrlController.dispose();
    _phoneNumberController.dispose();
    _aboutSectionTitleController.dispose();
    _aboutSectionBodyController.dispose();
    _aboutSectionImageUrlController.dispose();
    _partnershipTitleController.dispose();
    _partnershipBodyController.dispose();
    _partnershipImageUrlController.dispose();
    _partnershipCtaLabelController.dispose();
    _partnershipCtaUrlController.dispose();
    _footerTaglineController.dispose();
    _facebookUrlController.dispose();
    _instagramUrlController.dispose();
    _googleUrlController.dispose();
    _footerLegalTextController.dispose();
    _metaKeywordsController.dispose();
    _ogImageUrlController.dispose();
    _canonicalUrlController.dispose();
    super.dispose();
  }

  Future<void> _startWebsiteCheckout() async {
    final facility = _facility;
    final user = FirebaseAuth.instance.currentUser;
    if (facility == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Facility not found. Refresh and try again.'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    final isOwner =
        facility.currentUserOwnsFacility ?? facility.ownerUid == user?.uid;
    if (!isOwner) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The facility owner must activate the \$25/month website add-on.',
          ),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    final accountId = facility.facilityCreatorAccountId;
    final email = user?.email;
    if (accountId == null || accountId.isEmpty || email == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Billing account information is incomplete.'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    setState(() => _isStartingCheckout = true);
    try {
      final result = await StripeService.createWebsiteSubscriptionCheckout(
        accountId: accountId,
        facilityId: facility.id,
        customerEmail: email,
        successUrl:
            'https://app.storagefacilitycreator.com/#/website-setup?facilityId=${facility.id}',
        cancelUrl:
            'https://app.storagefacilitycreator.com/#/website-setup?facilityId=${facility.id}',
      );
      if (!mounted) return;
      if (result.subscriptionUpdated) {
        await _load();
        return;
      }
      final checkoutUrl = result.checkoutUrl;
      if (checkoutUrl == null || checkoutUrl.isEmpty) {
        throw Exception('Stripe did not return a checkout link.');
      }
      final opened = await launchUrl(
        Uri.parse(checkoutUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) throw Exception('Could not open Stripe Checkout.');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not start website checkout: $e'),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isStartingCheckout = false);
    }
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _subscriptionRequired = false;
      _error = null;
    });
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      final facilities = uid == null
          ? await FacilityService.getUserFacilities()
          : await ref.read(userFacilitiesProvider(uid).future);
      final facility = await FacilityService.getFacility(widget.facilityId);
      if (facility == null || !facility.hasActiveWebsiteSubscription) {
        if (!mounted) return;
        setState(() {
          _facility = facility;
          _userFacilities = facilities;
          _subscriptionRequired = true;
          _isLoading = false;
        });
        return;
      }
      final settings =
          await FacilityPublicService.getPublicSettings(widget.facilityId);
      final publicSlug = await FacilityMapV2Service.getPublicSlugForFacility(
          widget.facilityId);

      final widgets = settings?.widgets ?? const <String, dynamic>{};
      final websiteConfig =
          (widgets['websiteConfig'] as Map<String, dynamic>?) ??
              const <String, dynamic>{};
      final customStyles = settings?.customStyles ?? const <String, dynamic>{};
      final featuredImages = settings?.featuredImages ?? const <String>[];

      if (!mounted) return;
      setState(() {
        _facility = facility;
        _userFacilities = facilities;
        _websiteEnabled = settings?.enabled ?? false;
        _slugController.text =
            (settings?.publicRentalSlug?.trim().isNotEmpty ?? false)
                ? settings!.publicRentalSlug!
                : (publicSlug ?? widget.facilityId.toLowerCase());
        _customDomainController.text = settings?.customDomain ?? '';
        _pageTitleController.text =
            settings?.pageTitle ?? '${facility.name} | Self Storage';
        _pageDescriptionController.text = settings?.pageDescription ??
            (facility.description ??
                'Secure storage units with easy online rentals.');
        _heroHeadlineController.text =
            (websiteConfig['heroHeadline'] as String?)?.trim().isNotEmpty ==
                    true
                ? websiteConfig['heroHeadline'] as String
                : facility.name;
        _heroSubheadlineController.text = (websiteConfig['heroSubheadline']
                        as String?)
                    ?.trim()
                    .isNotEmpty ==
                true
            ? websiteConfig['heroSubheadline'] as String
            : 'Secure, convenient, and reliable storage with online rentals.';
        _marketingContentController.text = settings?.marketingContent ??
            'Choose from a wide range of unit sizes and reserve online in minutes.';
        _addressController.text = (websiteConfig['address'] as String?) ?? '';
        _officeHoursController.text = (websiteConfig['officeHours']
                as String?) ??
            'Mon-Fri: 8:00 AM - 6:00 PM\nSat: 9:00 AM - 5:00 PM\nSun: Closed';
        _amenitiesController.text = (websiteConfig['amenities'] as String?) ??
            'Online Rentals, Online Bill Pay, Drive-up Access, Secure Gate Access, Video Surveillance';
        _testimonialsController.text = (websiteConfig['testimonials']
                as String?) ??
            'Great facility and easy online rental process.\nClean units and friendly support.\nFast move-in and secure property.';
        _paymentUrlController.text =
            (websiteConfig['paymentUrl'] as String?) ?? '';
        _primaryCtaController.text =
            (websiteConfig['primaryCtaLabel'] as String?)?.trim().isNotEmpty ==
                    true
                ? websiteConfig['primaryCtaLabel'] as String
                : 'See Units';
        _secondaryCtaController.text =
            (websiteConfig['secondaryCtaLabel'] as String?)
                        ?.trim()
                        .isNotEmpty ==
                    true
                ? websiteConfig['secondaryCtaLabel'] as String
                : 'Make a Payment/Login';
        _taglineController.text = (websiteConfig['tagline'] as String?) ?? '';
        _heroImageUrlController.text =
            (websiteConfig['heroImageUrl'] as String?) ?? '';
        if (_heroImageUrlController.text.trim().isEmpty &&
            featuredImages.isNotEmpty) {
          _heroImageUrlController.text = featuredImages.first;
        }
        _contactEmailController.text =
            (websiteConfig['contactEmail'] as String?) ?? '';
        _mapEmbedUrlController.text =
            (websiteConfig['mapEmbedUrl'] as String?) ?? '';
        _promoTitleController.text =
            (websiteConfig['promoTitle'] as String?) ?? '';
        _promoBodyController.text =
            (websiteConfig['promoBody'] as String?) ?? '';
        _promoCtaLabelController.text =
            (websiteConfig['promoCtaLabel'] as String?) ?? '';
        _promoCtaUrlController.text =
            (websiteConfig['promoCtaUrl'] as String?) ?? '';
        _promiseSecurityController.text =
            (websiteConfig['promiseSecurity'] as String?) ?? '';
        _promiseServiceController.text =
            (websiteConfig['promiseService'] as String?) ?? '';
        _promiseConvenienceController.text =
            (websiteConfig['promiseConvenience'] as String?) ?? '';
        _reviewUrlController.text =
            (websiteConfig['reviewUrl'] as String?) ?? '';
        _stepChooseIconUrlController.text =
            (websiteConfig['stepChooseIconUrl'] as String?) ?? '';
        _stepDetailsIconUrlController.text =
            (websiteConfig['stepDetailsIconUrl'] as String?) ?? '';
        _stepReserveIconUrlController.text =
            (websiteConfig['stepReserveIconUrl'] as String?) ?? '';
        _promiseSecurityIconUrlController.text =
            (websiteConfig['promiseSecurityIconUrl'] as String?) ?? '';
        _promiseServiceIconUrlController.text =
            (websiteConfig['promiseServiceIconUrl'] as String?) ?? '';
        _promiseConvenienceIconUrlController.text =
            (websiteConfig['promiseConvenienceIconUrl'] as String?) ?? '';
        _heroGradientStartController.text =
            (customStyles['heroGradientStart'] as String?) ?? '#0C1E4D';
        _heroGradientEndController.text =
            (customStyles['heroGradientEnd'] as String?) ?? '#1E5BD4';
        _heroTextColorController.text =
            (customStyles['heroTextColor'] as String?) ?? '#FFFFFF';
        _ctaButtonColorController.text =
            (customStyles['ctaButtonColor'] as String?) ?? '#103A86';
        _logoImageUrlController.text =
            (websiteConfig['logoImageUrl'] as String?) ?? '';
        _phoneNumberController.text =
            (websiteConfig['phoneNumber'] as String?) ?? '';
        _showPaymentLoginButtonInHeader =
            websiteConfig['showPaymentLoginButtonInHeader'] != false;
        _aboutSectionTitleController.text =
            (websiteConfig['aboutSectionTitle'] as String?) ?? '';
        _aboutSectionBodyController.text =
            (websiteConfig['aboutSectionBody'] as String?) ?? '';
        _aboutSectionImageUrlController.text =
            (websiteConfig['aboutSectionImageUrl'] as String?) ?? '';
        _unitCategories = _normalizeListOfMaps(websiteConfig['unitCategories']);
        _amenitiesStructured =
            _normalizeListOfMaps(websiteConfig['amenitiesStructured']);
        _testimonialsStructured =
            _normalizeListOfMaps(websiteConfig['testimonialsStructured']);
        _faqs = _normalizeListOfMaps(websiteConfig['faqs']);
        final officeHoursStructuredRaw = websiteConfig['officeHoursStructured'];
        _useStructuredOfficeHours = officeHoursStructuredRaw is Map;
        _officeHoursStructured =
            _parseOfficeHoursStructured(officeHoursStructuredRaw);
        _partnershipTitleController.text =
            ((websiteConfig['partnershipBand'] as Map?)?['title'] as String?) ??
                '';
        _partnershipBodyController.text =
            ((websiteConfig['partnershipBand'] as Map?)?['body'] as String?) ??
                '';
        _partnershipImageUrlController.text = ((websiteConfig['partnershipBand']
                as Map?)?['imageUrl'] as String?) ??
            '';
        _partnershipCtaLabelController.text = ((websiteConfig['partnershipBand']
                as Map?)?['ctaLabel'] as String?) ??
            '';
        _partnershipCtaUrlController.text = ((websiteConfig['partnershipBand']
                as Map?)?['ctaUrl'] as String?) ??
            '';
        _footerTaglineController.text =
            (websiteConfig['footerTagline'] as String?) ?? '';
        _facebookUrlController.text =
            ((websiteConfig['socialLinks'] as Map?)?['facebook'] as String?) ??
                '';
        _instagramUrlController.text =
            ((websiteConfig['socialLinks'] as Map?)?['instagram'] as String?) ??
                '';
        _googleUrlController.text =
            ((websiteConfig['socialLinks'] as Map?)?['google'] as String?) ??
                '';
        _footerLegalTextController.text =
            (websiteConfig['footerLegalText'] as String?) ?? '';
        _metaKeywordsController.text =
            (websiteConfig['metaKeywords'] as String?) ?? '';
        _ogImageUrlController.text =
            (websiteConfig['ogImageUrl'] as String?) ?? '';
        _canonicalUrlController.text =
            (websiteConfig['canonicalUrl'] as String?) ?? '';
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load website settings: $e';
        _isLoading = false;
      });
    }
  }

  String get _slugPreview {
    final normalized = normalizePublicRentalSlug(_slugController.text);
    if (normalized.isNotEmpty) return normalized;
    return widget.facilityId.toLowerCase();
  }

  String _normalizeHexColor(String raw, {String fallback = '#103A86'}) {
    var value = raw.trim().replaceAll('#', '').toUpperCase();
    if (value.length == 3 && RegExp(r'^[0-9A-F]{3}$').hasMatch(value)) {
      value =
          '${value[0]}${value[0]}${value[1]}${value[1]}${value[2]}${value[2]}';
    }
    if (value.length == 6 && RegExp(r'^[0-9A-F]{6}$').hasMatch(value)) {
      return '#$value';
    }
    return fallback;
  }

  Color _parseHexColor(String raw, {Color fallback = const Color(0xFF103A86)}) {
    final normalized = _normalizeHexColor(
      raw,
      fallback:
          '#${fallback.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
    );
    final cleaned = normalized.replaceAll('#', '');
    if (cleaned.length == 6 && RegExp(r'^[0-9A-F]{6}$').hasMatch(cleaned)) {
      return Color(int.parse('FF$cleaned', radix: 16));
    }
    return fallback;
  }

  Future<void> _pickColor({
    required TextEditingController controller,
    required String title,
    required Color fallback,
  }) async {
    var selectedColor = _parseHexColor(controller.text, fallback: fallback);
    final picked = await showDialog<Color>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: BlockPicker(
              pickerColor: selectedColor,
              onColorChanged: (color) => selectedColor = color,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogContext).pop(selectedColor),
              child: const Text('Select'),
            ),
          ],
        );
      },
    );

    if (picked != null) {
      setState(() {
        controller.text =
            '#${picked.toARGB32().toRadixString(16).substring(2).toUpperCase()}';
      });
    }
  }

  /// Always works: SFC hosting `/w/{slug}` (no DNS setup on the operator's domain).
  String get _publicWebsiteUrl =>
      FacilityPublicService.getPublicWebsiteUrl(_slugPreview);

  /// Optional vanity host — only works after DNS + Firebase Hosting custom domain.
  String? get _customDomainWebsiteUrl {
    final domain = normalizeCustomDomain(_customDomainController.text);
    if (domain.isEmpty) return null;
    return 'https://$domain';
  }

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied'),
        backgroundColor: AppTheme.success,
      ),
    );
  }

  Future<void> _uploadImageToController(
    TextEditingController controller,
    String fieldKey,
  ) async {
    setState(() {
      _uploadingFieldKey = fieldKey;
      _error = null;
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['png', 'jpg', 'jpeg', 'webp', 'svg'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        setState(() => _uploadingFieldKey = null);
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
          'facilities/${widget.facilityId}/public-branding/website/$fieldKey-$stamp-$safeName';
      final ref = FirebaseStorage.instance.ref(path);
      await ref.putData(
        file.bytes!,
        SettableMetadata(contentType: contentType),
      );
      final url = await ref.getDownloadURL();
      if (!mounted) return;
      setState(() {
        controller.text = url;
        _uploadingFieldKey = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploadingFieldKey = null;
        _error = 'Image upload failed: $e';
      });
    }
  }

  bool _isHttpsUrlOrEmpty(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return true;
    final uri = Uri.tryParse(trimmed);
    return uri != null && uri.hasScheme && uri.scheme == 'https';
  }

  List<Map<String, dynamic>> _normalizeListOfMaps(dynamic raw) {
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((entry) => entry.map((k, v) => MapEntry(k.toString(), v)))
        .toList();
  }

  Map<String, _OfficeDayHours> _parseOfficeHoursStructured(dynamic raw) {
    final result = <String, _OfficeDayHours>{};
    for (final day in _dayOrder) {
      final fallback = _defaultOfficeHoursForDay(day);
      if (raw is Map && raw[day] is Map) {
        final map = (raw[day] as Map).map(
          (k, v) => MapEntry(k.toString(), v),
        );
        result[day] = _OfficeDayHours(
          open: (map['open'] as String?) ?? fallback.open,
          close: (map['close'] as String?) ?? fallback.close,
          closed: map['closed'] == true,
        );
      } else {
        result[day] = fallback;
      }
    }
    return result;
  }

  _OfficeDayHours _defaultOfficeHoursForDay(String day) {
    if (day == 'sunday') {
      return const _OfficeDayHours(open: '09:00', close: '21:00', closed: true);
    }
    return const _OfficeDayHours(open: '08:00', close: '21:00', closed: false);
  }

  String _dayLabel(String day) {
    if (day.isEmpty) return day;
    return day[0].toUpperCase() + day.substring(1);
  }

  Future<void> _pickOfficeHourTime({
    required String day,
    required bool isOpen,
  }) async {
    final current =
        _officeHoursStructured[day] ?? _defaultOfficeHoursForDay(day);
    final source = isOpen ? current.open : current.close;
    final parts = source.split(':');
    final initialHour = int.tryParse(parts.first) ?? 8;
    final initialMinute = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initialHour, minute: initialMinute),
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
    if (picked == null) return;
    setState(() {
      final next =
          _officeHoursStructured[day] ?? _defaultOfficeHoursForDay(day);
      final formatted =
          '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
      _officeHoursStructured[day] = isOpen
          ? next.copyWith(open: formatted)
          : next.copyWith(close: formatted);
    });
  }

  Map<String, dynamic>? _buildOfficeHoursStructuredPayload() {
    if (!_useStructuredOfficeHours) return null;
    return _dayOrder.fold<Map<String, dynamic>>(<String, dynamic>{},
        (acc, day) {
      final value =
          _officeHoursStructured[day] ?? _defaultOfficeHoursForDay(day);
      acc[day] = value.toMap();
      return acc;
    });
  }

  Future<void> _save() async {
    final slug = normalizePublicRentalSlug(_slugController.text);
    final customDomain = normalizeCustomDomain(_customDomainController.text);
    if (slug.isEmpty) {
      setState(() => _error = 'Please enter a valid website URL name.');
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      final httpsValidationMessages = <String>[];
      void validateHttps(String label, String value) {
        if (!_isHttpsUrlOrEmpty(value)) {
          httpsValidationMessages.add('$label must be an https:// URL.');
        }
      }

      validateHttps(
          'Hero background image', _heroImageUrlController.text.trim());
      validateHttps('Logo image', _logoImageUrlController.text.trim());
      validateHttps(
          'About section image', _aboutSectionImageUrlController.text.trim());
      validateHttps(
          'Partnership image', _partnershipImageUrlController.text.trim());
      validateHttps(
          'Partnership CTA URL', _partnershipCtaUrlController.text.trim());
      validateHttps('Facebook URL', _facebookUrlController.text.trim());
      validateHttps('Instagram URL', _instagramUrlController.text.trim());
      validateHttps('Google URL', _googleUrlController.text.trim());
      validateHttps('OG image URL', _ogImageUrlController.text.trim());
      validateHttps('Canonical URL', _canonicalUrlController.text.trim());
      for (var i = 0; i < _unitCategories.length; i++) {
        validateHttps(
          'Unit category #${i + 1} hero image',
          (_unitCategories[i]['heroImageUrl'] ?? '').toString(),
        );
      }
      if (httpsValidationMessages.isNotEmpty) {
        throw Exception(httpsValidationMessages.join('\n'));
      }

      final currentSettings =
          await FacilityPublicService.getPublicSettings(widget.facilityId);
      final currentWidgets =
          currentSettings?.widgets ?? const <String, dynamic>{};
      final sanitizedUnitCategories = _unitCategories
          .map((entry) => <String, dynamic>{
                'slug': (entry['slug'] ?? '').toString().trim(),
                'name': (entry['name'] ?? '').toString().trim(),
                'shortBlurb': (entry['shortBlurb'] ?? '').toString().trim(),
                'longDescription':
                    (entry['longDescription'] ?? '').toString().trim(),
                'heroImageUrl': (entry['heroImageUrl'] ?? '').toString().trim(),
                'startingPrice': double.tryParse(
                    (entry['startingPrice'] ?? '').toString().trim()),
                'ctaLabel': (entry['ctaLabel'] ?? '').toString().trim(),
                'displayOrder': int.tryParse(
                    (entry['displayOrder'] ?? '').toString().trim()),
              })
          .where((entry) =>
              (entry['slug'] as String).isNotEmpty &&
              (entry['name'] as String).isNotEmpty)
          .toList();
      final sanitizedAmenitiesStructured = _amenitiesStructured
          .map((entry) => <String, dynamic>{
                'label': (entry['label'] ?? '').toString().trim(),
                'icon': (entry['icon'] ?? '').toString().trim(),
              })
          .where((entry) => (entry['label'] as String).isNotEmpty)
          .toList();
      final sanitizedTestimonialsStructured = _testimonialsStructured
          .map((entry) => <String, dynamic>{
                'quote': (entry['quote'] ?? '').toString().trim(),
                'reviewer': (entry['reviewer'] ?? '').toString().trim(),
                'rating': int.tryParse((entry['rating'] ?? '').toString()) ?? 5,
                'source': (entry['source'] ?? '').toString().trim(),
              })
          .where((entry) => (entry['quote'] as String).isNotEmpty)
          .toList();
      final sanitizedFaqs = _faqs
          .map((entry) => <String, dynamic>{
                'question': (entry['question'] ?? '').toString().trim(),
                'answer': (entry['answer'] ?? '').toString().trim(),
              })
          .where((entry) =>
              (entry['question'] as String).isNotEmpty &&
              (entry['answer'] as String).isNotEmpty)
          .toList();
      final partnershipBand = <String, dynamic>{
        'title': _partnershipTitleController.text.trim(),
        'body': _partnershipBodyController.text.trim(),
        'imageUrl': _partnershipImageUrlController.text.trim(),
        'ctaLabel': _partnershipCtaLabelController.text.trim(),
        'ctaUrl': _partnershipCtaUrlController.text.trim(),
      };
      final socialLinks = <String, dynamic>{
        'facebook': _facebookUrlController.text.trim(),
        'instagram': _instagramUrlController.text.trim(),
        'google': _googleUrlController.text.trim(),
      };
      final mergedWidgets = <String, dynamic>{
        ...currentWidgets,
        'websiteTemplate': 'cookie-cutter-v2',
        'websiteConfig': <String, dynamic>{
          'heroHeadline': _heroHeadlineController.text.trim(),
          'heroSubheadline': _heroSubheadlineController.text.trim(),
          'address': _addressController.text.trim(),
          'officeHours': _officeHoursController.text.trim(),
          'amenities': _amenitiesController.text.trim(),
          'testimonials': _testimonialsController.text.trim(),
          'paymentUrl': _paymentUrlController.text.trim(),
          'primaryCtaLabel': _primaryCtaController.text.trim(),
          'secondaryCtaLabel': _secondaryCtaController.text.trim(),
          'tagline': _taglineController.text.trim(),
          'heroImageUrl': _heroImageUrlController.text.trim(),
          'contactEmail': _contactEmailController.text.trim(),
          'mapEmbedUrl': _mapEmbedUrlController.text.trim(),
          'promoTitle': _promoTitleController.text.trim(),
          'promoBody': _promoBodyController.text.trim(),
          'promoCtaLabel': _promoCtaLabelController.text.trim(),
          'promoCtaUrl': _promoCtaUrlController.text.trim(),
          'promiseSecurity': _promiseSecurityController.text.trim(),
          'promiseService': _promiseServiceController.text.trim(),
          'promiseConvenience': _promiseConvenienceController.text.trim(),
          'stepChooseIconUrl': _stepChooseIconUrlController.text.trim(),
          'stepDetailsIconUrl': _stepDetailsIconUrlController.text.trim(),
          'stepReserveIconUrl': _stepReserveIconUrlController.text.trim(),
          'promiseSecurityIconUrl':
              _promiseSecurityIconUrlController.text.trim(),
          'promiseServiceIconUrl': _promiseServiceIconUrlController.text.trim(),
          'promiseConvenienceIconUrl':
              _promiseConvenienceIconUrlController.text.trim(),
          'reviewUrl': _reviewUrlController.text.trim(),
          'logoImageUrl': _logoImageUrlController.text.trim(),
          'phoneNumber': _phoneNumberController.text.trim(),
          'showPaymentLoginButtonInHeader': _showPaymentLoginButtonInHeader,
          'officeHoursStructured': _buildOfficeHoursStructuredPayload(),
          'unitCategories':
              sanitizedUnitCategories.isEmpty ? null : sanitizedUnitCategories,
          'amenitiesStructured': sanitizedAmenitiesStructured.isEmpty
              ? null
              : sanitizedAmenitiesStructured,
          'testimonialsStructured': sanitizedTestimonialsStructured.isEmpty
              ? null
              : sanitizedTestimonialsStructured,
          'partnershipBand':
              partnershipBand.values.every((v) => v.toString().trim().isEmpty)
                  ? null
                  : partnershipBand,
          'footerTagline': _footerTaglineController.text.trim(),
          'socialLinks':
              socialLinks.values.every((v) => v.toString().trim().isEmpty)
                  ? null
                  : socialLinks,
          'footerLegalText': _footerLegalTextController.text.trim(),
          'metaKeywords': _metaKeywordsController.text.trim(),
          'ogImageUrl': _ogImageUrlController.text.trim(),
          'canonicalUrl': _canonicalUrlController.text.trim(),
          'aboutSectionTitle': _aboutSectionTitleController.text.trim(),
          'aboutSectionBody': _aboutSectionBodyController.text.trim(),
          'aboutSectionImageUrl': _aboutSectionImageUrlController.text.trim(),
          'faqs': sanitizedFaqs.isEmpty ? null : sanitizedFaqs,
        },
      };

      await FacilityPublicService.updatePublicSettings(
        facilityId: widget.facilityId,
        enabled: _websiteEnabled,
        publicRentalsEnabled: true,
        publicRentalSlug: slug,
        customDomain: customDomain.isEmpty ? null : customDomain,
        pageTitle: _pageTitleController.text.trim().isEmpty
            ? null
            : _pageTitleController.text.trim(),
        pageDescription: _pageDescriptionController.text.trim().isEmpty
            ? null
            : _pageDescriptionController.text.trim(),
        marketingContent: _marketingContentController.text.trim().isEmpty
            ? null
            : _marketingContentController.text.trim(),
        featuredImages: _heroImageUrlController.text.trim().isEmpty
            ? null
            : <String>[_heroImageUrlController.text.trim()],
        customStyles: <String, dynamic>{
          'heroGradientStart': _normalizeHexColor(
              _heroGradientStartController.text,
              fallback: '#0C1E4D'),
          'heroGradientEnd': _normalizeHexColor(_heroGradientEndController.text,
              fallback: '#1E5BD4'),
          'heroTextColor': _normalizeHexColor(_heroTextColorController.text,
              fallback: '#FFFFFF'),
          'ctaButtonColor': _normalizeHexColor(_ctaButtonColorController.text,
              fallback: '#103A86'),
        },
        widgets: mergedWidgets,
      );

      await FacilityMapV2Service.setPublicSlug(
        facilityId: widget.facilityId,
        slug: slug,
      );
      await FacilityMapV2Service.publishCurrentDraft(
          facilityId: widget.facilityId);

      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Website settings saved and published.'),
          backgroundColor: AppTheme.success,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _error = 'Failed to save website settings: $e';
      });
    }
  }

  Widget _buildOptionalSection({
    required String title,
    required List<Widget> children,
    String? subtitle,
    bool initiallyExpanded = false,
  }) {
    return Card(
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          subtitle ?? '(optional — leave blank to use defaults)',
          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: children,
      ),
    );
  }

  List<Widget> _buildOfficeHoursRows() {
    return _dayOrder.map((day) {
      final hours =
          _officeHoursStructured[day] ?? _defaultOfficeHoursForDay(day);
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            SizedBox(
              width: 92,
              child: Text(
                _dayLabel(day),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Expanded(
              child: OutlinedButton(
                onPressed: hours.closed
                    ? null
                    : () => _pickOfficeHourTime(day: day, isOpen: true),
                child: Text('Open: ${hours.open}'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: hours.closed
                    ? null
                    : () => _pickOfficeHourTime(day: day, isOpen: false),
                child: Text('Close: ${hours.close}'),
              ),
            ),
            const SizedBox(width: 8),
            Checkbox(
              value: hours.closed,
              onChanged: (value) {
                setState(() {
                  final current = _officeHoursStructured[day] ??
                      _defaultOfficeHoursForDay(day);
                  _officeHoursStructured[day] =
                      current.copyWith(closed: value ?? false);
                });
              },
            ),
            const Text('Closed'),
          ],
        ),
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_subscriptionRequired) {
      final user = FirebaseAuth.instance.currentUser;
      final facility = _facility;
      final isOwner = facility == null
          ? false
          : (facility.currentUserOwnsFacility ??
              facility.ownerUid == user?.uid);
      return Center(
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline,
                    size: 48, color: AppTheme.textSecondary),
                const SizedBox(height: 12),
                const Text(
                  'Website subscription required',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  isOwner
                      ? 'Activate the optional \$25/month website add-on for this '
                          'facility. You need an active \$75 platform subscription first. '
                          'After Stripe confirms payment, Website Setup unlocks.'
                      : 'The facility owner must activate the \$25/month website '
                          'add-on before this page can be configured.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                if (isOwner)
                  FilledButton.icon(
                    onPressed:
                        _isStartingCheckout ? null : _startWebsiteCheckout,
                    icon: _isStartingCheckout
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.payment),
                    label: Text(
                      _isStartingCheckout
                          ? 'Opening Stripe...'
                          : 'Continue to payment',
                    ),
                  )
                else
                  FilledButton(
                    onPressed: () => context.go(AppRoute.settings),
                    child: const Text('Back to Settings'),
                  ),
                if (isOwner) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _isStartingCheckout ? null : _load,
                    child: const Text('I already paid — refresh'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            const Text(
              'Website Setup',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            if (_facility != null &&
                _facility!.hasActiveStripeWebsiteSubscription &&
                !_facility!.websiteSubscriptionCancelAtPeriodEnd)
              TextButton.icon(
                onPressed: () async {
                  final done = await CancellationRetentionWizard.show(
                    context,
                    facility: _facility!,
                    initialPlanType: 'website',
                  );
                  if (done == true && mounted) await _load();
                },
                icon: const Icon(Icons.cancel_outlined, size: 18),
                label: const Text('Cancel website plan'),
              )
            else if (_facility?.websiteSubscriptionCancelAtPeriodEnd == true)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Text(
                  'Cancelling at period end',
                  style: TextStyle(color: AppTheme.warning),
                ),
              ),
            IconButton(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'One public marketing website per facility using our fixed template.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 16),
        if (_userFacilities.length > 1) ...[
          DropdownButtonFormField<String>(
            initialValue: widget.facilityId,
            decoration: const InputDecoration(
              labelText: 'Facility',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.apartment),
            ),
            items: _userFacilities
                .map((f) => DropdownMenuItem<String>(
                      value: f.id,
                      child: Text(f.name),
                    ))
                .toList(),
            onChanged: (value) {
              if (value == null || value == widget.facilityId) return;
              context.go('/website-setup?facilityId=$value');
            },
          ),
          const SizedBox(height: 12),
        ],
        Text(
          _facility?.name ?? 'Facility',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        _buildOptionalSection(
          title: '1. Website Basics',
          subtitle: 'Enable the site and set your URL / custom domain',
          initiallyExpanded: true,
          children: [
            const Text(
              'Website layout',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              'Standard public website — homepage, units, map, and contact info',
            ),
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _websiteEnabled,
              onChanged: (v) => setState(() => _websiteEnabled = v),
              title: const Text('Website Enabled'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _slugController,
              decoration: const InputDecoration(
                labelText: 'Website URL Name',
                hintText: 'your-facility',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.link),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _customDomainController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Custom Domain (optional)',
                hintText: 'yourfacility.com',
                helperText:
                    'Your real domain — apex (yourfacility.com), www, or a subdomain. Must match what Super Admin connects in Hosting. '
                    'After Connect, add the DNS records Firebase shows at GoDaddy (or your registrar). '
                    'Until DNS is live, use the public /w/… link below.',
                helperMaxLines: 4,
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.language),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildOptionalSection(
          title: '2. Branding Colors',
          children: [
            const Text(
              'These colors style the live rental site hero + CTA buttons.',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 12),
            _ColorPickerField(
              controller: _heroGradientStartController,
              label: 'Hero gradient start color',
              hintText: '#0C1E4D',
              fallback: const Color(0xFF0C1E4D),
              onPick: () => _pickColor(
                controller: _heroGradientStartController,
                title: 'Hero gradient start',
                fallback: const Color(0xFF0C1E4D),
              ),
              previewColor: _parseHexColor(
                _heroGradientStartController.text,
                fallback: const Color(0xFF0C1E4D),
              ),
            ),
            const SizedBox(height: 10),
            _ColorPickerField(
              controller: _heroGradientEndController,
              label: 'Hero gradient end color',
              hintText: '#1E5BD4',
              fallback: const Color(0xFF1E5BD4),
              onPick: () => _pickColor(
                controller: _heroGradientEndController,
                title: 'Hero gradient end',
                fallback: const Color(0xFF1E5BD4),
              ),
              previewColor: _parseHexColor(
                _heroGradientEndController.text,
                fallback: const Color(0xFF1E5BD4),
              ),
            ),
            const SizedBox(height: 10),
            _ColorPickerField(
              controller: _heroTextColorController,
              label: 'Hero text color',
              hintText: '#FFFFFF',
              fallback: Colors.white,
              onPick: () => _pickColor(
                controller: _heroTextColorController,
                title: 'Hero text color',
                fallback: Colors.white,
              ),
              previewColor: _parseHexColor(
                _heroTextColorController.text,
                fallback: Colors.white,
              ),
            ),
            const SizedBox(height: 10),
            _ColorPickerField(
              controller: _ctaButtonColorController,
              label: 'CTA button color',
              hintText: '#103A86',
              fallback: const Color(0xFF103A86),
              onPick: () => _pickColor(
                controller: _ctaButtonColorController,
                title: 'CTA button color',
                fallback: const Color(0xFF103A86),
              ),
              previewColor: _parseHexColor(
                _ctaButtonColorController.text,
                fallback: const Color(0xFF103A86),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildOptionalSection(
          title: '3. Hero & Page Copy',
          children: [
            TextField(
              controller: _pageTitleController,
              decoration: const InputDecoration(
                labelText: 'Page Title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pageDescriptionController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Page Description',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _heroHeadlineController,
              decoration: const InputDecoration(
                labelText: 'Hero Headline',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _heroSubheadlineController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Hero Subheadline',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _taglineController,
              decoration: const InputDecoration(
                labelText: 'Header Tagline (under facility name)',
                hintText: 'Climate controlled & drive-up self storage',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _heroImageUrlController,
              decoration: InputDecoration(
                labelText: 'Hero Background Image URL (https only)',
                hintText: 'https://.../photo.jpg',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.image_outlined),
                suffixIcon: IconButton(
                  onPressed: _uploadingFieldKey == 'hero-image'
                      ? null
                      : () => _uploadImageToController(
                            _heroImageUrlController,
                            'hero-image',
                          ),
                  icon: _uploadingFieldKey == 'hero-image'
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.upload_file),
                  tooltip: 'Upload image',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildOptionalSection(
          title: '4. Icons',
          children: [
            const Text(
              'Upload once and save. These icons appear on the public cookie-cutter page.',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 10),
            _UploadableUrlField(
              controller: _stepChooseIconUrlController,
              label: 'Step 1 icon (Choose unit)',
              fieldKey: 'step-choose-icon',
              uploadingFieldKey: _uploadingFieldKey,
              onUpload: _uploadImageToController,
            ),
            const SizedBox(height: 10),
            _UploadableUrlField(
              controller: _stepDetailsIconUrlController,
              label: 'Step 2 icon (Enter details)',
              fieldKey: 'step-details-icon',
              uploadingFieldKey: _uploadingFieldKey,
              onUpload: _uploadImageToController,
            ),
            const SizedBox(height: 10),
            _UploadableUrlField(
              controller: _stepReserveIconUrlController,
              label: 'Step 3 icon (Reserve online)',
              fieldKey: 'step-reserve-icon',
              uploadingFieldKey: _uploadingFieldKey,
              onUpload: _uploadImageToController,
            ),
            const SizedBox(height: 10),
            _UploadableUrlField(
              controller: _promiseSecurityIconUrlController,
              label: 'Why Rent icon: Security',
              fieldKey: 'why-security-icon',
              uploadingFieldKey: _uploadingFieldKey,
              onUpload: _uploadImageToController,
            ),
            const SizedBox(height: 10),
            _UploadableUrlField(
              controller: _promiseServiceIconUrlController,
              label: 'Why Rent icon: Service',
              fieldKey: 'why-service-icon',
              uploadingFieldKey: _uploadingFieldKey,
              onUpload: _uploadImageToController,
            ),
            const SizedBox(height: 10),
            _UploadableUrlField(
              controller: _promiseConvenienceIconUrlController,
              label: 'Why Rent icon: Convenience',
              fieldKey: 'why-convenience-icon',
              uploadingFieldKey: _uploadingFieldKey,
              onUpload: _uploadImageToController,
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildOptionalSection(
          title: '5. Location & Contact',
          children: [
            TextField(
              controller: _marketingContentController,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Main Marketing Paragraph',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _addressController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Address',
                hintText: '123 Main St, City, ST 12345',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _contactEmailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Contact Email (optional)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.email_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _mapEmbedUrlController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Google Maps Embed URL (optional)',
                helperText:
                    'From Google Maps: Share → Embed a map → copy the iframe src URL (https://www.google.com/maps/embed?...)',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
                prefixIcon: Icon(Icons.map_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _paymentUrlController,
              decoration: const InputDecoration(
                labelText: 'Payment/Login URL (optional)',
                hintText: 'https://...',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildOptionalSection(
          title: '6. Promo Band & CTAs',
          children: [
            TextField(
              controller: _promoTitleController,
              decoration: const InputDecoration(
                labelText: 'Promo band title (optional)',
                hintText: 'Making your move easier',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _promoBodyController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Promo band paragraph (optional)',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _promoCtaLabelController,
                    decoration: const InputDecoration(
                      labelText: 'Promo CTA label',
                      hintText: 'Learn more',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _promoCtaUrlController,
                    decoration: const InputDecoration(
                      labelText: 'Promo CTA URL',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _promiseSecurityController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Our promise — Security (optional override)',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _promiseServiceController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Our promise — Customer service (optional)',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _promiseConvenienceController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Our promise — Convenience (optional)',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _reviewUrlController,
              decoration: const InputDecoration(
                labelText: 'Review link (optional, footer)',
                hintText: 'Google Business review URL',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.reviews_outlined),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _primaryCtaController,
                    decoration: const InputDecoration(
                      labelText: 'Primary CTA Label',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _secondaryCtaController,
                    decoration: const InputDecoration(
                      labelText: 'Secondary CTA Label',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildOptionalSection(
          title: '7. Branding & Header',
          children: [
            TextField(
              controller: _logoImageUrlController,
              decoration: InputDecoration(
                labelText: 'Logo Image URL (https)',
                hintText: 'https://.../logo.png',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.image_outlined),
                suffixIcon: IconButton(
                  onPressed: _uploadingFieldKey == 'header-logo'
                      ? null
                      : () => _uploadImageToController(
                            _logoImageUrlController,
                            'header-logo',
                          ),
                  icon: _uploadingFieldKey == 'header-logo'
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.upload_file),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phoneNumberController,
              decoration: const InputDecoration(
                labelText: 'Phone Number',
                hintText: '(555) 123-4567',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.phone_outlined),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show Payment/Login button in header'),
              value: _showPaymentLoginButtonInHeader,
              onChanged: (value) => setState(
                () => _showPaymentLoginButtonInHeader = value,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildOptionalSection(
          title: '8. About Section',
          children: [
            TextField(
              controller: _aboutSectionTitleController,
              decoration: const InputDecoration(
                labelText: 'About Section Title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _aboutSectionBodyController,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'About Section Body (markdown allowed)',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _aboutSectionImageUrlController,
              decoration: const InputDecoration(
                labelText: 'About Section Image URL (https)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.image_outlined),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildOptionalSection(
          title: '9. Unit Categories',
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () {
                  setState(() {
                    _unitCategories.add(<String, dynamic>{
                      'slug': '',
                      'name': '',
                      'shortBlurb': '',
                      'longDescription': '',
                      'heroImageUrl': '',
                      'startingPrice': '',
                      'ctaLabel': 'Learn More',
                      'displayOrder': _unitCategories.length + 1,
                    });
                  });
                },
                icon: const Icon(Icons.add),
                label: const Text('Add category'),
              ),
            ),
            const SizedBox(height: 8),
            ...List.generate(_unitCategories.length, (index) {
              final item = _unitCategories[index];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Text('Category ${index + 1}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                          const Spacer(),
                          IconButton(
                            onPressed: () => setState(
                              () => _unitCategories.removeAt(index),
                            ),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                      TextFormField(
                        initialValue: (item['slug'] ?? '').toString(),
                        decoration: const InputDecoration(
                          labelText: 'Slug',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (value) => item['slug'] = value,
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        initialValue: (item['name'] ?? '').toString(),
                        decoration: const InputDecoration(
                          labelText: 'Name',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (value) => item['name'] = value,
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        initialValue: (item['shortBlurb'] ?? '').toString(),
                        decoration: const InputDecoration(
                          labelText: 'Short blurb',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (value) => item['shortBlurb'] = value,
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        initialValue:
                            (item['longDescription'] ?? '').toString(),
                        maxLines: 4,
                        decoration: const InputDecoration(
                          labelText: 'Long description (markdown allowed)',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                        onChanged: (value) => item['longDescription'] = value,
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        initialValue: (item['heroImageUrl'] ?? '').toString(),
                        decoration: const InputDecoration(
                          labelText: 'Hero image URL (https)',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (value) => item['heroImageUrl'] = value,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              initialValue:
                                  (item['startingPrice'] ?? '').toString(),
                              decoration: const InputDecoration(
                                labelText: 'Starting price',
                                border: OutlineInputBorder(),
                              ),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              onChanged: (value) =>
                                  item['startingPrice'] = value,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextFormField(
                              initialValue:
                                  (item['displayOrder'] ?? '').toString(),
                              decoration: const InputDecoration(
                                labelText: 'Display order',
                                border: OutlineInputBorder(),
                              ),
                              keyboardType: TextInputType.number,
                              onChanged: (value) =>
                                  item['displayOrder'] = value,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        initialValue: (item['ctaLabel'] ?? '').toString(),
                        decoration: const InputDecoration(
                          labelText: 'CTA Label',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (value) => item['ctaLabel'] = value,
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
        const SizedBox(height: 12),
        _buildOptionalSection(
          title: '10. Amenities',
          children: [
            TextField(
              controller: _amenitiesController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Amenities (comma separated)',
                hintText:
                    'Online Rentals, Online Bill Pay, Drive-up Access, Climate Control',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () {
                  setState(() {
                    _amenitiesStructured.add(<String, dynamic>{
                      'label': '',
                      'icon': _amenityIconOptions.first,
                    });
                  });
                },
                icon: const Icon(Icons.add),
                label: const Text('Add amenity'),
              ),
            ),
            const SizedBox(height: 8),
            ...List.generate(_amenitiesStructured.length, (index) {
              final item = _amenitiesStructured[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        initialValue: (item['label'] ?? '').toString(),
                        decoration: const InputDecoration(
                          labelText: 'Amenity label',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (value) => item['label'] = value,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _amenityIconOptions
                                .contains((item['icon'] ?? '').toString())
                            ? (item['icon'] ?? '').toString()
                            : _amenityIconOptions.first,
                        decoration: const InputDecoration(
                          labelText: 'Icon',
                          border: OutlineInputBorder(),
                        ),
                        items: _amenityIconOptions
                            .map(
                              (icon) => DropdownMenuItem<String>(
                                value: icon,
                                child: Text(icon),
                              ),
                            )
                            .toList(),
                        onChanged: (value) => item['icon'] = value ?? 'clock',
                      ),
                    ),
                    IconButton(
                      onPressed: () => setState(
                        () => _amenitiesStructured.removeAt(index),
                      ),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
        const SizedBox(height: 12),
        _buildOptionalSection(
          title: '11. Testimonials',
          children: [
            TextField(
              controller: _testimonialsController,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Testimonials (one per line)',
                hintText:
                    'Great facility... --- Jane D.\nUse --- before the reviewer name (optional).',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () {
                  setState(() {
                    _testimonialsStructured.add(<String, dynamic>{
                      'quote': '',
                      'reviewer': '',
                      'rating': 5,
                      'source': '',
                    });
                  });
                },
                icon: const Icon(Icons.add),
                label: const Text('Add testimonial'),
              ),
            ),
            const SizedBox(height: 8),
            ...List.generate(_testimonialsStructured.length, (index) {
              final item = _testimonialsStructured[index];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Text('Testimonial ${index + 1}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                          const Spacer(),
                          IconButton(
                            onPressed: () => setState(
                              () => _testimonialsStructured.removeAt(index),
                            ),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                      TextFormField(
                        initialValue: (item['quote'] ?? '').toString(),
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Quote',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                        onChanged: (value) => item['quote'] = value,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              initialValue: (item['reviewer'] ?? '').toString(),
                              decoration: const InputDecoration(
                                labelText: 'Reviewer',
                                border: OutlineInputBorder(),
                              ),
                              onChanged: (value) => item['reviewer'] = value,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: DropdownButtonFormField<int>(
                              initialValue: (item['rating'] as int?) ?? 5,
                              decoration: const InputDecoration(
                                labelText: 'Rating',
                                border: OutlineInputBorder(),
                              ),
                              items: List.generate(
                                5,
                                (i) => DropdownMenuItem<int>(
                                  value: i + 1,
                                  child: Text('${i + 1}'),
                                ),
                              ),
                              onChanged: (value) => item['rating'] = value ?? 5,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        initialValue: (item['source'] ?? '').toString(),
                        decoration: const InputDecoration(
                          labelText: 'Source',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (value) => item['source'] = value,
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
        const SizedBox(height: 12),
        _buildOptionalSection(
          title: '12. Office Hours',
          children: [
            TextField(
              controller: _officeHoursController,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Office Hours (freeform)',
                hintText:
                    'Mon-Fri: 8:00 AM - 6:00 PM\nSat: 9:00 AM - 5:00 PM\nSun: Closed',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use structured day-by-day office hours'),
              subtitle: const Text(
                  'When enabled, this replaces the legacy freeform office hours on public pages.'),
              value: _useStructuredOfficeHours,
              onChanged: (value) =>
                  setState(() => _useStructuredOfficeHours = value),
            ),
            if (_useStructuredOfficeHours) ..._buildOfficeHoursRows(),
          ],
        ),
        const SizedBox(height: 12),
        _buildOptionalSection(
          title: '13. Partnership / Secondary Promo Band',
          children: [
            TextField(
              controller: _partnershipTitleController,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _partnershipBodyController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Body',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _partnershipImageUrlController,
              decoration: const InputDecoration(
                labelText: 'Image URL (https)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _partnershipCtaLabelController,
                    decoration: const InputDecoration(
                      labelText: 'CTA label',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _partnershipCtaUrlController,
                    decoration: const InputDecoration(
                      labelText: 'CTA URL (https)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildOptionalSection(
          title: '14. FAQ',
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () {
                  setState(() {
                    _faqs.add(<String, dynamic>{'question': '', 'answer': ''});
                  });
                },
                icon: const Icon(Icons.add),
                label: const Text('Add FAQ'),
              ),
            ),
            const SizedBox(height: 8),
            ...List.generate(_faqs.length, (index) {
              final item = _faqs[index];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Text('FAQ ${index + 1}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                          const Spacer(),
                          IconButton(
                            onPressed: () =>
                                setState(() => _faqs.removeAt(index)),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                      TextFormField(
                        initialValue: (item['question'] ?? '').toString(),
                        decoration: const InputDecoration(
                          labelText: 'Question',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (value) => item['question'] = value,
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        initialValue: (item['answer'] ?? '').toString(),
                        maxLines: 4,
                        decoration: const InputDecoration(
                          labelText: 'Answer',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                        onChanged: (value) => item['answer'] = value,
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
        const SizedBox(height: 12),
        _buildOptionalSection(
          title: '15. Footer & Social',
          children: [
            TextField(
              controller: _footerTaglineController,
              decoration: const InputDecoration(
                labelText: 'Footer tagline',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _facebookUrlController,
              decoration: const InputDecoration(
                labelText: 'Facebook URL (https)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _instagramUrlController,
              decoration: const InputDecoration(
                labelText: 'Instagram URL (https)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _googleUrlController,
              decoration: const InputDecoration(
                labelText: 'Google URL (https)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _footerLegalTextController,
              decoration: const InputDecoration(
                labelText: 'Footer legal text',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildOptionalSection(
          title: '16. SEO',
          children: [
            TextField(
              controller: _metaKeywordsController,
              decoration: const InputDecoration(
                labelText: 'Meta keywords',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _ogImageUrlController,
              decoration: const InputDecoration(
                labelText: 'OG image URL (https)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _canonicalUrlController,
              decoration: const InputDecoration(
                labelText: 'Canonical URL (https)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildOptionalSection(
          title: '17. Publish Links',
          subtitle: 'Copy links after publishing',
          children: [
            _WebsiteLinkRow(
              label: 'Public website link (works now)',
              value: _publicWebsiteUrl,
              onCopy: _copy,
            ),
            if (_customDomainWebsiteUrl != null) ...[
              const Divider(),
              _WebsiteLinkRow(
                label: 'Custom domain (needs DNS + Hosting)',
                value: _customDomainWebsiteUrl!,
                onCopy: _copy,
              ),
            ],
            const Divider(),
            _WebsiteLinkRow(
              label: 'Website JSON',
              value: FacilityPublicService.getPublicWebsiteConfigUrl(
                  _slugPreview),
              onCopy: _copy,
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: AppTheme.error)),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () =>
                    _copy('Public website link', _publicWebsiteUrl),
                icon: const Icon(Icons.copy),
                label: const Text('Copy public link'),
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
                label: Text(_isSaving ? 'Saving...' : 'Save Website'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _WebsiteLinkRow extends StatelessWidget {
  final String label;
  final String value;
  final Future<void> Function(String label, String value) onCopy;

  const _WebsiteLinkRow({
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
          onPressed: () => onCopy(label, value),
          icon: const Icon(Icons.copy, size: 18),
          tooltip: 'Copy',
        ),
      ],
    );
  }
}

class _ColorPickerField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hintText;
  final Color fallback;
  final VoidCallback onPick;
  final Color previewColor;

  const _ColorPickerField({
    required this.controller,
    required this.label,
    required this.hintText,
    required this.fallback,
    required this.onPick,
    required this.previewColor,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        border: const OutlineInputBorder(),
        prefixIcon: const Icon(Icons.palette_outlined),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: previewColor,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.black.withValues(alpha: 0.2),
                ),
              ),
            ),
            IconButton(
              onPressed: onPick,
              icon: const Icon(Icons.color_lens_outlined),
              tooltip: 'Pick color',
            ),
          ],
        ),
      ),
      onTapOutside: (_) {
        final normalized = controller.text.trim();
        if (normalized.isEmpty) {
          controller.text =
              '#${fallback.toARGB32().toRadixString(16).substring(2).toUpperCase()}';
        }
      },
    );
  }
}

class _UploadableUrlField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String fieldKey;
  final String? uploadingFieldKey;
  final Future<void> Function(TextEditingController, String) onUpload;

  const _UploadableUrlField({
    required this.controller,
    required this.label,
    required this.fieldKey,
    required this.uploadingFieldKey,
    required this.onUpload,
  });

  @override
  Widget build(BuildContext context) {
    final isUploading = uploadingFieldKey == fieldKey;
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        hintText: 'https://...',
        border: const OutlineInputBorder(),
        prefixIcon: const Icon(Icons.link),
        suffixIcon: IconButton(
          onPressed: isUploading ? null : () => onUpload(controller, fieldKey),
          icon: isUploading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.upload_file),
          tooltip: 'Upload image',
        ),
      ),
    );
  }
}

class _OfficeDayHours {
  final String open;
  final String close;
  final bool closed;

  const _OfficeDayHours({
    required this.open,
    required this.close,
    required this.closed,
  });

  _OfficeDayHours copyWith({
    String? open,
    String? close,
    bool? closed,
  }) {
    return _OfficeDayHours(
      open: open ?? this.open,
      close: close ?? this.close,
      closed: closed ?? this.closed,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'open': open,
      'close': close,
      'closed': closed,
    };
  }
}
