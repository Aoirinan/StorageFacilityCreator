import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../models/facility_model.dart';
import '../services/facility_map_v2_service.dart';
import '../services/facility_public_service.dart';
import '../services/facility_service.dart';
import '../theme/app_theme.dart';
import '../utils/renter_account_message.dart';

class FacilityWebsiteSetupScreen extends StatefulWidget {
  final String facilityId;

  const FacilityWebsiteSetupScreen({
    super.key,
    required this.facilityId,
  });

  @override
  State<FacilityWebsiteSetupScreen> createState() =>
      _FacilityWebsiteSetupScreenState();
}

class _FacilityWebsiteSetupScreenState
    extends State<FacilityWebsiteSetupScreen> {
  bool _isLoading = true;
  bool _isSaving = false;
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
  final TextEditingController _promoCtaLabelController = TextEditingController();
  final TextEditingController _promoCtaUrlController = TextEditingController();
  final TextEditingController _promiseSecurityController = TextEditingController();
  final TextEditingController _promiseServiceController = TextEditingController();
  final TextEditingController _promiseConvenienceController = TextEditingController();
  final TextEditingController _reviewUrlController = TextEditingController();

  bool _websiteEnabled = true;

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

      final widgets = settings?.widgets ?? const <String, dynamic>{};
      final websiteConfig =
          (widgets['websiteConfig'] as Map<String, dynamic>?) ??
              const <String, dynamic>{};

      if (!mounted) return;
      setState(() {
        _facility = facility;
        _userFacilities = facilities;
        _websiteEnabled = settings?.enabled ?? true;
        _slugController.text =
            (settings?.publicRentalSlug?.trim().isNotEmpty ?? false)
                ? settings!.publicRentalSlug!
                : (publicSlug ?? widget.facilityId.toLowerCase());
        _customDomainController.text = settings?.customDomain ?? '';
        _pageTitleController.text = settings?.pageTitle ??
            '${facility?.name ?? 'Storage Facility'} | Self Storage';
        _pageDescriptionController.text = settings?.pageDescription ??
            (facility?.description ??
                'Secure storage units with easy online rentals.');
        _heroHeadlineController.text =
            (websiteConfig['heroHeadline'] as String?)?.trim().isNotEmpty ==
                    true
                ? websiteConfig['heroHeadline'] as String
                : '${facility?.name ?? 'Storage Facility'}';
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
        _contactEmailController.text =
            (websiteConfig['contactEmail'] as String?) ?? '';
        _mapEmbedUrlController.text =
            (websiteConfig['mapEmbedUrl'] as String?) ?? '';
        _promoTitleController.text =
            (websiteConfig['promoTitle'] as String?) ?? '';
        _promoBodyController.text = (websiteConfig['promoBody'] as String?) ?? '';
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
        _reviewUrlController.text = (websiteConfig['reviewUrl'] as String?) ?? '';
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
      final currentSettings =
          await FacilityPublicService.getPublicSettings(widget.facilityId);
      final currentWidgets =
          currentSettings?.widgets ?? const <String, dynamic>{};
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
          'reviewUrl': _reviewUrlController.text.trim(),
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

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
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
            IconButton(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Build one cookie-cutter website per facility using a fixed template.',
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
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Template',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                const Text('Cookie Cutter v2 (hero, map, promise, promo band)'),
                const SizedBox(height: 10),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _websiteEnabled,
                  onChanged: (v) => setState(() => _websiteEnabled = v),
                  title: const Text('Website Enabled'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
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
            hintText: 'rent.yourfacility.com',
            helperText:
                'Only works after you add this exact hostname in Firebase Hosting → Custom domains and create the DNS records your registrar shows (often a CNAME). Until then, use the public website link below — "site can\'t be reached" means DNS is not set up yet.',
            helperMaxLines: 4,
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.language),
          ),
        ),
        const SizedBox(height: 12),
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
          decoration: const InputDecoration(
            labelText: 'Hero Background Image URL (https only)',
            hintText: 'https://.../photo.jpg',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.image_outlined),
          ),
        ),
        const SizedBox(height: 12),
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
          controller: _officeHoursController,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Office Hours',
            hintText:
                'Mon-Fri: 8:00 AM - 6:00 PM\nSat: 9:00 AM - 5:00 PM\nSun: Closed',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 12),
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
        TextField(
          controller: _paymentUrlController,
          decoration: const InputDecoration(
            labelText: 'Payment/Login URL (optional)',
            hintText: 'https://...',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
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
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
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
